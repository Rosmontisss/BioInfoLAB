#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

############################################
#  配置
############################################
GATK="/home/s59022116/anaconda3/envs/SNP/bin/gatk"
SAMTOOLS="/home/s59022116/anaconda3/envs/SNP/bin/samtools"
REF="/home/s59022116/LuoLab/Reference_Gene/Homo_sapiens.GRCh38.dna.toplevel.fa"
DBSNP="/home/s59022116/LuoLab/Reference_Gene/dbsnp_156.hg38.vcf.gz"
BAM_DIR="/home/s59022116/LuoLab/SortedBam"
OUT_ROOT="/home/s59022116/LuoLab/RNA_Mu_result_final"
# 全局并发任务上限
GLOBAL_MAX_JOBS=4
# 各阶段线程需求(每个样本使用的线程数)
declare -A THREAD_REQ=( [add_rg]=6 [mark_dup]=6 [split_n_cigar]=6 [hc]=12 )
# 各阶段内存需求(每个样本的内存MB数)
declare -A MEM_REQ=( [add_rg]=10240 [mark_dup]=10240 [split_n_cigar]=20480 [hc]=40960 )
# 染色体区间
INTERVALS=( -L 11 -L 14 )
ALL_STAGES=(add_rg mark_dup split_n_cigar hc)

############################################
#  系统资源
############################################
CPU_COUNT=$(nproc)
echo "[INFO] 检测到 $CPU_COUNT 个逻辑CPU"
AVAILABLE_MEM_MB=$(awk '/MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo)
echo "[INFO] 可用内存: ${AVAILABLE_MEM_MB} MB"

############################################
#  收集样本
############################################
echo "[INFO] 收集已索引的BAM文件..."
cd "$BAM_DIR"
mapfile -t SAMPLES < <(for bam in *.bam; do
  [[ -s "${bam%.bam}.bai" || -s "${bam}.bai" ]] && echo "${bam%.bam}"
done)
(( ${#SAMPLES[@]} )) || { echo "[ERROR] 未找到已索引的BAM文件" >&2; exit 1; }
echo "[INFO] 找到 ${#SAMPLES[@]} 个样本: ${SAMPLES[*]}"

############################################
#  样本处理函数
############################################
process_sample() {
  local stage=$1 sample=$2
  local bam outdir in out metrics cmd
  bam="$BAM_DIR/${sample}.bam"
  outdir="$OUT_ROOT/${sample}"
  mkdir -p "$outdir/processBAM" "$outdir/variants"
  case "$stage" in
    add_rg)
      out="$outdir/processBAM/${sample}.RG.bam"
      cmd=("$GATK" AddOrReplaceReadGroups --INPUT "$bam" --OUTPUT "$out" \
           --RGID "$sample" --RGLB lib1 --RGPL illumina --RGPU unit1 --RGSM "$sample" \
           --java-options "-Xmx10g")
      ;;
    mark_dup)
      in="$outdir/processBAM/${sample}.RG.bam"
      out="$outdir/processBAM/${sample}.RG.markdup.bam"
      metrics="$outdir/processBAM/${sample}.markdup.metrics.txt"
      cmd=(bash -c "set -e; $GATK MarkDuplicates -I '$in' -O '$out' -M '$metrics' --java-options '-Xmx10g'; \
             $SAMTOOLS index '$out'")
      ;;
    split_n_cigar)
      in="$outdir/processBAM/${sample}.RG.markdup.bam"
      out="$outdir/processBAM/${sample}.RG.markdup.split.bam"
      cmd=("$GATK" SplitNCigarReads --R "$REF" --I "$in" --O "$out" "${INTERVALS[@]}" \
           --java-options "-Xmx20g")
      ;;
    hc)
      in="$outdir/processBAM/${sample}.RG.markdup.split.bam"
      out="$outdir/variants/${sample}.g.vcf.gz"
      cmd=("$GATK" HaplotypeCaller -R "$REF" -I "$in" -O "$out" \
           --emit-ref-confidence GVCF --standard-min-confidence-threshold-for-calling 20 \
           --dbsnp "$DBSNP" --native-pair-hmm-threads "${THREAD_REQ[hc]}" \
           --java-options "-Xmx40g" "${INTERVALS[@]}")
      ;;
    *) echo "[ERROR] 未知阶段: $stage"; exit 1 ;;  
  esac
  echo ">>> [$stage] 处理样本 $sample"
  [[ -s "$out" ]] && { echo "[SKIP] $sample"; return; }
  echo "[RUN ] $sample"
  "${cmd[@]}"
  echo "[DONE] $sample"
}
export -f process_sample
export GATK SAMTOOLS REF DBSNP BAM_DIR OUT_ROOT THREAD_REQ MEM_REQ

############################################
#  主流程
############################################
for stage in "${ALL_STAGES[@]}"; do
  echo
  echo "===== 阶段: $stage ====="
  # 根据CPU和内存计算最大并发任务数
  req_mem=${MEM_REQ[$stage]}
  req_thr=${THREAD_REQ[$stage]}
  max_by_mem=$(( AVAILABLE_MEM_MB / req_mem ))
  max_by_cpu=$(( CPU_COUNT / req_thr ))
  jobs=$(( max_by_mem < max_by_cpu ? max_by_mem : max_by_cpu ))
  (( jobs > GLOBAL_MAX_JOBS )) && jobs=$GLOBAL_MAX_JOBS
  (( jobs < 1 )) && jobs=1
  echo "[INFO] 阶段=$stage 每个任务需要 ${req_mem}MB 内存和 ${req_thr} 个线程 -> 启动 $jobs 个并发任务"
  printf "%s\n" "${SAMPLES[@]}" | parallel --jobs "$jobs" process_sample "$stage" {}
  echo "===== 完成: $stage ====="
done

echo "[INFO] 流程成功完成!"
