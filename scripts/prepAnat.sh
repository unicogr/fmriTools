#!/bin/bash
# BIDS-compatible anatomical preprocessing (denoising, optional resampling, and segmentation)
# Usage: bash prepAnat.sh sub-01 ses-01 [--segment] [--isotropic] [threshold]

# Parse arguments
segment=false
isotropic=false
threshold=0.5

while [[ $# -gt 0 ]]; do
  case $1 in
    --segment)
      segment=true
      shift
      ;;
    --isotropic)
      isotropic=true
      shift
      ;;
    -t|--threshold)
      threshold="$2"
      shift 2
      ;;
    *)
      if [ -z "$subj_number" ]; then
        subj_number="$1"
      elif [ -z "$session" ]; then
        session="$1"
      else
        echo "Unknown argument: $1"
        exit 1
      fi
      shift
      ;;
  esac
done

# Check required arguments
if [ -z "$subj_number" ] || [ -z "$session" ]; then
  echo "Usage: bash prepAnat.sh sub-01 ses-01 [--segment] [--isotropic] [threshold]"
  exit 1
fi

# Load configuration values from conf.yaml
user_folder=$(yq -r '.Paths.user_folder' conf.yaml)
project_folder=$(yq -r '.Paths.project_folder' conf.yaml)
programs_path=$(yq -r '.Paths.programs_path' conf.yaml)
anat_type=$(yq -r '.MRI.anatomical' conf.yaml)

# Debug: Echo paths to verify
echo "Debug: user_folder=$user_folder"
echo "Debug: project_folder=$project_folder"
echo "Debug: programs_path=$programs_path"

# Construct BIDS anat directory
output_folder="${user_folder}${project_folder}/output"
anat_folder="${output_folder}/${subj_number}/${session}/anat"
fs_subjects_dir="${output_folder}/fs_subjects"

# Check if anat folder exists
if [ ! -d "$anat_folder" ]; then
    echo "ERROR: Anat folder not found: $anat_folder. Run BIDS conversion first."
    exit 1
fi

cd "$anat_folder" || { echo "Failed to change to anat folder: $anat_folder"; exit 1; }

# Set up FSL, FreeSurfer, and ANTs

# FSL
FSLDIR=${programs_path}/fsl
. ${FSLDIR}/etc/fslconf/fsl.sh
PATH=${FSLDIR}/bin:${PATH}
export FSLDIR PATH

# Freesurfer
unset FREESURFER_HOME
#export FREESURFER_HOME=${programs_path}freesurfer/8.0.0
export FREESURFER_HOME=${programs_path}/freesurfer
source $FREESURFER_HOME/SetUpFreeSurfer.sh
#export SUBJECTS_DIR=$FREESURFER_HOME/subjects
export SUBJECTS_DIR=$fs_subjects_dir
mkdir -p $SUBJECTS_DIR

# ANTs
export PATH=${programs_path}/ants-2.5.4/bin:$PATH

# Prefix for files (BIDS convention)
prefix="${subj_number}_${session}"

# Input files (BIDS convention, in anat folder)
uni="${anat_folder}/${prefix}_UNIDEN.nii.gz"  # UNI image
t1="${anat_folder}/${prefix}_T1map.nii.gz"    # T1 image
inv2="${anat_folder}/${prefix}_inv-2_part-mag_MP2RAGE.nii.gz"  # INV2 image

# Check for required input files
for file in "$uni" "$t1" "$inv2"; do
    if [ ! -f "$file" ]; then
        echo "ERROR: Required file not found: $file"
        exit 1
    fi
done

echo "Starting anatomical denoising for $subj_number $session with threshold $threshold"

# Step 1: Binarize INV2 (keep non-baseline values)
fslmaths "$inv2" -thr "$threshold" "${anat_folder}/${prefix}_inv2_bin.nii.gz" -odt float

# Step 2: Mask UNI with binarized INV2
fslmaths "$uni" -mas "${anat_folder}/${prefix}_inv2_bin.nii.gz" "${anat_folder}/${prefix}_t1_tmp.nii.gz" -odt float

# Step 3: Threshold to remove outliers
fslmaths "${anat_folder}/${prefix}_t1_tmp.nii.gz" -uthr 5 "${anat_folder}/${prefix}_t1_thr.nii.gz" -odt float

# Step 4: Correct T1 inhomogeneity (N4 algorithm)
N4BiasFieldCorrection -i "${anat_folder}/${prefix}_t1_tmp.nii.gz" -o "${anat_folder}/${prefix}_t1_corrected_N4.nii.gz" -v -s 4 -c [50x50x50x50] -b [200] -t [0.15] -d 3

# Step 5: Copy corrected file to final T1w.nii.gz (overwrites or creates)
cp "${anat_folder}/${prefix}_t1_corrected_N4.nii.gz" "${anat_folder}/${prefix}_T1w.nii.gz"

# Optional: Clean up intermediate files (uncomment if desired)
# rm -f "${anat_folder}/${prefix}_inv2_bin.nii.gz" \
#       "${anat_folder}/${prefix}_t1_tmp.nii.gz" \
#       "${anat_folder}/${prefix}_t1_thr.nii.gz"

echo "Anatomical denoising complete for $subj_number $session. Output: ${anat_folder}/${prefix}_T1w.nii.gz"

# If segmentation flag is set, proceed with FreeSurfer segmentation
if [ "$segment" = true ]; then
    echo "Proceeding with FreeSurfer segmentation..."

    # Set FreeSurfer subjects dir
    # export SUBJECTS_DIR="$fs_subjects_dir"  # Already set above
    mkdir -p "$SUBJECTS_DIR"

    # Subject ID for FreeSurfer
    subj_iso="${prefix}_iso"

    # Input for segmentation
    input_file="${anat_folder}/${prefix}_T1w.nii.gz"

    # Optional isotropic resampling
    if [ "$isotropic" = true ]; then
        iso_file="${anat_folder}/${prefix}_T1w_1mm_iso.nii.gz"
        if [ ! -f "$iso_file" ]; then
            echo "Resampling to isotropic 1mm voxels..."
            flirt -in "$input_file" \
                  -ref "$input_file" \
                  -applyisoxfm 1.0 -nosearch \
                  -out "$iso_file"
        else
            echo "$iso_file already exists, skipping isotropic resampling."
        fi
        segmentation_input="$iso_file"
    else
        segmentation_input="$input_file"
    fi

    # Run FreeSurfer recon-all
    echo "Running FreeSurfer recon-all..."
    recon-all -i "$segmentation_input" -subjid "$subj_iso" -all

    echo "FreeSurfer segmentation complete for $subj_number $session"
else
    echo "Segmentation not requested. Manual check recommended before running with --segment."
fi
