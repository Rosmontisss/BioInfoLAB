#!/bin/bash

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

handle_error() {
    echo -e "${RED}$1${NC}" >&2
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || { handle_error "需要安装 $1"; exit 1; }
}
check_file() {
    [ -f "$1" ] || { handle_error "文件不存在: $1"; exit 1; }
}

# 固定路径
INPUT_DIR="/home/s59022116/LuoLab/RNA_Mu_result_final"
REF_GENOME="/home/s59022116/LuoLab/Reference_Gene/Homo_sapiens.GRCh38.dna.toplevel.fa"
OUTPUT_DIR="${INPUT_DIR}/population"
CSV_LOG="${OUTPUT_DIR}/run_summary.csv"

# 依赖检查
check_command gatk
check_command tabix
check_file "$REF_GENOME"
check_file "${REF_GENOME}.fai"
check_file "${REF_GENOME%.fa*}.dict"

mkdir -p "$OUTPUT_DIR"

# 若 CSV 不存在则写表头
[ -f "$CSV_LOG" ] || echo "Prefix,Sample,GVCF_Path,Index_OK,Combined_GVCF,Final_VCF,SNP_VCF,Indel_VCF,Time" > "$CSV_LOG"

# 按前缀处理
for prefix in GZ XJ ZC; do
    echo -e "${GREEN}=== 处理前缀 $prefix ===${NC}"

    out_sub="${OUTPUT_DIR}/${prefix}"
    mkdir -p "$out_sub"

    combined_gvcf="${out_sub}/${prefix}.g.vcf.gz"
    final_vcf="${out_sub}/${prefix}.vcf.gz"
    snp_vcf="${out_sub}/${prefix}.snp.vcf.gz"
    indel_vcf="${out_sub}/${prefix}.indel.vcf.gz"

    # 收集 gVCF
    sample_dirs=("$INPUT_DIR"/${prefix}*"_sorted")
    gvcf_list=()
    for d in "${sample_dirs[@]}"; do
        g="${d}/variants/$(basename "$d").g.vcf.gz"
        [ -f "$g" ] || continue
        gvcf_list+=("$g")
    done

    if [ ${#gvcf_list[@]} -eq 0 ]; then
        echo -e "${YELLOW}未发现 $prefix 样本${NC}"
        continue
    fi

    # 索引
    for g in "${gvcf_list[@]}"; do
        samp=$(basename "$g" .g.vcf.gz)
        idx_ok="OK"
        if [ ! -f "${g}.tbi" ]; then
            if tabix -p vcf "$g"; then
                idx_ok="OK"
            else
                idx_ok="FAIL"
            fi
        fi
        echo "$prefix,$samp,$g,$idx_ok,,,,,$(date '+%F %T')" >> "$CSV_LOG"
    done

    # 构建 CombineGVCFs 参数
    vcf_args=""
    for g in "${gvcf_list[@]}"; do vcf_args="${vcf_args} -V $g"; done

    # CombineGVCFs
    c_ok="SKIP"; [ ! -f "$combined_gvcf" ] && {
        echo -e "${GREEN}合并 gVCF → $combined_gvcf${NC}"
        if time gatk CombineGVCFs -R "$REF_GENOME" $vcf_args -O "$combined_gvcf"; then
            tabix -p vcf "$combined_gvcf"
            c_ok="OK"
        else
            c_ok="FAIL"
        fi
    }
    echo "$prefix,COMBINE,,,$c_ok,,,$(date '+%F %T')" >> "$CSV_LOG"

    # GenotypeGVCFs
    g_ok="SKIP"; [ ! -f "$final_vcf" ] && {
        echo -e "${GREEN}基因型检测 → $final_vcf${NC}"
        if time gatk GenotypeGVCFs -R "$REF_GENOME" -V "$combined_gvcf" -O "$final_vcf"; then
            tabix -p vcf "$final_vcf"
            g_ok="OK"
        else
            g_ok="FAIL"
        fi
    }
    echo "$prefix,GENOTYPE,,,,$g_ok,,$(date '+%F %T')" >> "$CSV_LOG"

    # SelectVariants SNP/INDEL
    for vtype in SNP INDEL; do
        out_var="${out_sub}/${prefix}.${vtype,,}.vcf.gz"
        s_ok="SKIP"; [ ! -f "$out_var" ] && {
            echo -e "${GREEN}筛选 $vtype → $out_var${NC}"
            if time gatk SelectVariants -select-type "$vtype" -V "$final_vcf" -O "$out_var"; then
                tabix -p vcf "$out_var"
                s_ok="OK"
            else
                s_ok="FAIL"
            fi
        }
        echo "$prefix,SELECT_${vtype},,,,,$s_ok,$(date '+%F %T')" >> "$CSV_LOG"
    done

    echo -e "${GREEN}=== $prefix 完成 ===${NC}"
done

echo -e "${GREEN}全部流程结束，日志见: $CSV_LOG${NC}"
