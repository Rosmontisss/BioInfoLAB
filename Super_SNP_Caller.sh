#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# Optimized Multi-sample, Multi-interval GATK HaplotypeCaller
# Uses GNU parallel for better job control and reduced overhead
# Implements three-tier splitting:
#   1) by chromosome
#   2) by reference N-gap complements
#   3) by per-sample coverage complements
#===============================================================================

##### 0) Configuration #####
GATK="/home/s59022116/anaconda3/envs/SNP/bin/gatk"
REF_FASTA="/home/s59022116/LuoLab/Reference_Gene/Homo_sapiens.GRCh38.dna.toplevel.fa"
BAM_DIR="/home/s59022116/LuoLab/RNA_Mu_result_final"
OUT_ROOT="/home/s59022116/LuoLab/RNA_VCF"
THREADS=24               # total CPU cores
HMM_THREADS=6            # threads per HaplotypeCaller job
JAVA_MEM="8g"          # Java heap per job
MAX_JOBS=$(( THREADS / HMM_THREADS ))  # number of parallel jobs
TMPDIR="/home/s59022116/LuoLab/TEM"

# tools
SAMTOOLS="/home/s59022116/anaconda3/envs/SNP/bin/samtools"
BEDTOOLS="bedtools"
SEQKIT="seqkit"
PARALLEL="parallel"

mkdir -p "$OUT_ROOT" "$TMPDIR"

##### 1) Index and extract contigs #####
echo "[INFO] Indexing FASTA and extracting contig lengths..."
$SAMTOOLS faidx "$REF_FASTA"
cut -f1,2 "${REF_FASTA}.fai" > "$TMPDIR/ref_contigs.txt"

##### 2) Compute reference gap complement #####
echo "[INFO] Identifying N-gap runs (>=10 Ns) in reference..."
$SEQKIT locate -j "$THREADS" -r -p '"N{10,}"' "$REF_FASTA" \
  | tail -n +2 | awk '{OFS="\t"; print $1, $5-1, $6}' > "$TMPDIR/ref_n_gaps.bed"
echo "[INFO] Creating complement intervals of N-gaps..."
$BEDTOOLS complement -i "$TMPDIR/ref_n_gaps.bed" -g "$TMPDIR/ref_contigs.txt" > "$TMPDIR/ref_gap_complement.bed"

##### 3) Generate and run per-sample commands #####
find "$BAM_DIR" -type f -name "*_mkdup.bam" | while read -r bam; do
  sample=$(basename "$bam" _mkdup.bam)
  sample_dir="$OUT_ROOT/$sample"
  mkdir -p "$sample_dir"
  echo "[SAMPLE] $sample"

  # Strategy 3: low-coverage complement
  echo "[INFO] Computing low-coverage (<3×) regions for $sample..."
  $BEDTOOLS genomecov -bga -ibam "$bam" -g "$TMPDIR/ref_contigs.txt" \
    | awk '$4 < 3' | $BEDTOOLS merge -i - > "$TMPDIR/${sample}_lowcov.bed"
  echo "[INFO] Complement of low-coverage regions..."
  $BEDTOOLS complement -i "$TMPDIR/${sample}_lowcov.bed" -g "$TMPDIR/ref_contigs.txt" > "$TMPDIR/${sample}_cov_complement.bed"

  # Final usable intervals
  echo "[INFO] Intersecting reference and coverage complements..."
  $BEDTOOLS intersect -a "$TMPDIR/ref_gap_complement.bed" \
      -b "$TMPDIR/${sample}_cov_complement.bed" > "$TMPDIR/${sample}_intervals.bed"

  # filter very small chunks
  echo "[INFO] Filtering intervals <500 bp..."
  awk '{ if ($3 - $2 >= 500) print $0 }' "$TMPDIR/${sample}_intervals.bed" > "$TMPDIR/${sample}_filtered.bed"
  mv "$TMPDIR/${sample}_filtered.bed" "$TMPDIR/${sample}_intervals.bed"

  # prepare parallel commands
  echo "[INFO] Preparing GNU parallel command list..."
  > "$TMPDIR/${sample}_hc_cmds.sh"
  while read -r chr start end; do
    interval="${chr}:$((start+1))-$end"
    out_vcf="$sample_dir/${sample}.${chr}_${start}_${end}.vcf.gz"
    echo "$GATK --java-options \"-Xmx${JAVA_MEM}\" HaplotypeCaller -R $REF_FASTA -I $bam --genotyping-mode DISCOVERY --intervals $interval --native-pair-hmm-threads $HMM_THREADS -stand-call-conf 30 --sample-ploidy 2 -O $out_vcf" >> "$TMPDIR/${sample}_hc_cmds.sh"
  done < "$TMPDIR/${sample}_intervals.bed"

  # run with GNU parallel
  echo "[INFO] Running HaplotypeCaller for $sample with up to $MAX_JOBS parallel jobs..."
  $PARALLEL -j $MAX_JOBS < "$TMPDIR/${sample}_hc_cmds.sh"

  echo "[INFO] Merging per-interval VCFs for $sample..."
  merge_args=()
  for v in "$sample_dir"/${sample}.*.vcf.gz; do
    merge_args+=( -I "$v" )
  done
  $GATK MergeVcfs "${merge_args[@]}" -O "$sample_dir/${sample}.HC.vcf.gz"
  echo "[INFO] Completed sample $sample"

done

# cleanup
echo "[INFO] Cleaning temporary files..."
rm -rf "$TMPDIR"
echo "[INFO] All samples processed."

