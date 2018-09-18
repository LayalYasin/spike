import os
import socket
import glob

from scripts.parse_samplesheet import parse_samplesheet, get_role, get_reference_genome, get_reference_knowns, get_reference_exometrack, get_species, get_reference_varscan_somatic, get_global_samplesheets
from scripts.parse_samplesheet import get_trios, get_tumorNormalPairs, get_samples, get_bwa_mem_header, get_demux_samples, get_projects_with_exomecoverage, get_rejoin_fastqs, get_xenograft_hybridreference, get_xenograft_stepname, get_persamplefastq_samples
from scripts.utils import exclude_sample
from scripts.checks import check_illuminarun_complete
from scripts.reports import report_undertermined_filesizes, report_exome_coverage
from scripts.convert_platypus import annotate


if socket.gethostname().startswith("hilbert") or socket.gethostname().startswith("murks"):
    # I now prefer to use the bcl2fastq version shipped via conda!
    # this loads a highly parallelized version of bcl2fastq compiled by HHU-HPC's guys
    # shell.prefix("module load bcl2fastq;")
    shell.prefix("module load R;")

configfile: "config.yaml"
SAMPLESHEETS = get_global_samplesheets(os.path.join(config['dirs']['prefix'], config['dirs']['inputs'], config['dirs']['samplesheets']))

include: "rules/demultiplex/Snakefile"
include: "rules/backup/Snakefile"
include: "rules/rejoin_samples/Snakefile"
include: "rules/trim/Snakefile"
include: "rules/xenograft/Snakefile"
include: "rules/map/Snakefile"
include: "rules/gatk/Snakefile"
include: "rules/platypus/Snakefile"
include: "rules/varscan/Snakefile"
include: "rules/freec/Snakefile"
include: "rules/mutect/Snakefile"

localrules: check_complete, aggregate_undetermined_filesizes, check_undetermined_filesizes, convert_illumina_report, check_coverage, xenograft_check, per_sample_fastq, correct_genotypes_somatic, correct_genotypes, varscan_fpfilter_somatic, somatic_FPfilter, somatic_reduce, vcf_annotate, merge_somatic_mus_musculus, merge_somatic_homo_sapiens, platypus_filtered

rule all:
    input:
        # create a yield report per run as one of the checkpoints for the wetlab crew
        # don't create yield report for per sample fastq projects!
        yield_report=["%s%s%s/%s.yield_report.pdf" % (config['dirs']['prefix'], config['dirs']['reports'], run, run)
                      for run in set(SAMPLESHEETS['run'].unique()) - set(get_persamplefastq_samples(SAMPLESHEETS, config))],

        # # create backup for each run
        # # don't backup per sample fastq runs
        # backup=["%s%s%s.%s.done" % (config['dirs']['prefix'], config['dirs']['checks'], run, config['stepnames']['backup_validate'])
        #         for run in set(SAMPLESHEETS['run'].unique()) - set(get_persamplefastq_samples(SAMPLESHEETS, config))],

        # demultiplex all samples for projects that ONLY need to demultiplex, e.g. AG_Remke
        demux=['%s%s%s/%s' % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['demultiplex'], run)
               for run in get_demux_samples(SAMPLESHEETS, config)],

        # as an alternative to demultiplexing, for cases were we have per sample fastqs (as in Macrogen) we copy those input file into the according demux directory and ensure proper naming
        persamplefastq=['%s%s%s/%s' % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['demultiplex'], run)
                        for run in get_persamplefastq_samples(SAMPLESHEETS, config)],

        # check exome coverage per project
        coverage_report=['%s%s%s.exome_coverage.pdf' % (config['dirs']['prefix'], config['dirs']['reports'], project) for project in get_projects_with_exomecoverage(config)],

        # snv calling against background for all samples of all runs (this is the "main pipeline")
        background_ptp=['%s%s%s/%s.ptp.annotated.filtered.indels.vcf' % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['platypus_filtered'], sample['sample'])
                        for sample in get_samples(SAMPLESHEETS, config)],
        background_gatk=['%s%s%s/%s.gatk.%ssnp_indel.vcf' % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['gatk_CombineVariants'], sample['sample'], isrelax)
                         for sample in get_samples(SAMPLESHEETS, config)
                         for isrelax in ['', 'relax.']],

        # tumornormal calling for complete tumor/normal pairs of all runs
        tumornormal_freec=['%s%s%s/%s/%s/tumor.pileup.gz_BAF.txt'          % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['freec'],         pair['Sample_Project'], pair['ukd_entity_id']) for pair in get_tumorNormalPairs(SAMPLESHEETS, config)],
        tumornormal_mutect=['%s%s%s/%s/%s.all_calls.vcf.gz'                % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['mutect'],        pair['Sample_Project'], pair['ukd_entity_id']) for pair in get_tumorNormalPairs(SAMPLESHEETS, config)],
        tumornormal_varscan_mouse=['%s%s%s/%s/%s.indel_snp.vcf'            % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['merge_somatic'], pair['Sample_Project'], pair['ukd_entity_id']) for pair in get_tumorNormalPairs(SAMPLESHEETS, config, species="mus musculus")],
        tumornormal_varscan_human=['%s%s%s/%s/%s.snp.somatic_germline.vcf' % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['merge_somatic'], pair['Sample_Project'], pair['ukd_entity_id']) for pair in get_tumorNormalPairs(SAMPLESHEETS, config, species="homo sapiens")],

        # trio calling for complete trios of all runs
        trio_calling=['%s%s%s/%s/%s.var2denovo.vcf' % (config['dirs']['prefix'], config['dirs']['intermediate'], config['stepnames']['writing_headers'], trio['Sample_Project'], trio['ukd_entity_id']) for trio in get_trios(SAMPLESHEETS, config)],

# onerror:
#     print("An error occurred")
#     shell("mail -s 'an error occurred' stefan.m.janssen@gmail.com < {log}")
