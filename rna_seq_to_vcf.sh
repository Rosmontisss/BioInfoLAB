#!/bin/bash

# mapping BAM to vcf
# 注意：变量赋值时=两边不能有空格，路径需替换为实际安装位置

# 软件及参考文件路径（请根据实际情况修改）
gatk=/home/s59022116/anaconda3/envs/SNP/bin/gatk  # GATK可执行文件路径
samtools=/home/s59022116/anaconda3/envs/SNP/bin/samtools  # samtools路径
ref_genome=/home/s59022116/LuoLab/Reference_Gene/Homo_sapiens.GRCh38.dna.toplevel.fa  # 参考基因组路径
dbsnp=/home/s59022116/LuoLab/Reference_Gene/dbsnp_156.hg38.vcf.gz  # dbSNP路径

# 输入参数（从命令行传入）
BAM=$1          # 输入BAM文件路径（如：/path/to/sample.bam）
RGID=$2         # Read Group ID（如：RG123）
library=$3      # 文库编号（如：LIB001）
sample=$4       # 样本名称（如：Sample001）
outdir=$5       # 输出根目录（如：/path/to/output）
THREADS=${6:-16}  # 线程数（默认16，可通过第6个参数调整）

# 按样本创建输出目录（修复原脚本中变量赋值空格错误）
outdir=${outdir}/${sample}
mkdir -p $outdir/variants $outdir/processBAM  # 一次性创建所有目录

# 1. 为BAM文件添加Read Group标签
time $gatk AddOrReplaceReadGroups \
    --INPUT $BAM \
    --OUTPUT $outdir/processBAM/${sample}.RG.bam \
    --RGID $RGID \
    --RGLB $library \
    --RGPL illumina \
    --RGPU snpcall \
    --RGSM $sample \
    --java-options "-Xmx8g" &&  # 分配8GB内存
echo "** [1/4] ADD RG done for $sample **"

# 2. 标记PCR重复并建立索引
time $gatk MarkDuplicates \
    -I $outdir/processBAM/${sample}.RG.bam \
    -M $outdir/processBAM/${sample}.markdup_metrics.txt \
    -O $outdir/processBAM/${sample}.RG.markdup.bam \
    --java-options "-Xmx16g" &&  # 标记重复需要更多内存
time $samtools index $outdir/processBAM/${sample}.RG.markdup.bam &&  # 建立BAM索引
echo "** [2/4] MarkDuplicates done for $sample **"

# 3. 处理剪接位点（SplitNCigarReads，修复参数格式，移除-nct，用Java参数控制线程）
time $gatk SplitNCigarReads \
    -R $ref_genome \
    -I $outdir/processBAM/${sample}.RG.markdup.bam \
    -O $outdir/processBAM/${sample}.RG.markdup.split.bam \
    --java-options "-Xmx16g -XX:ParallelGCThreads=$THREADS" &&  # 分配内存和线程
echo "** [3/4] SplitNCigarReads done for $sample **"

# 4. 变异检测（HaplotypeCaller，移除无效参数，优化内存配置）
time $gatk HaplotypeCaller \
    -R $ref_genome \
    -I $outdir/processBAM/${sample}.RG.markdup.split.bam \
    -O $outdir/variants/${sample}.g.vcf.gz \
    -dont-use-soft-clipped-bases \
    --emit-ref-confidence GVCF \
    --standard-min-confidence-threshold-for-calling 20 \
    --dbsnp $dbsnp \
    --java-options "-Xmx32g -XX:ParallelGCThreads=$THREADS" &&  # 大内存支持（根据服务器调整）
echo "** [4/4] HaplotypeCaller done for $sample **"

# 检查最终输出文件是否存在
if [ -f "$outdir/variants/${sample}.g.vcf.gz" ]; then
    echo "** 样本 $sample 处理完成！输出文件：$outdir/variants/${sample}.g.vcf.gz **"
else
    echo "** 样本 $sample 处理失败！请检查日志 **" >&2
    exit 1
fi
