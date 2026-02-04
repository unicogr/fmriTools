## Prepare atlases for ROI mapping: Generate Benson and Wang atlases using neuropythy and convert to .curv format
# Run this before roiMapper_test.py to ensure atlas files are available
# Usage: bash /home_local/Nico/fmriTools/scripts/prepAtlases.sh [--subject <subj>] [--session <ses_num>]
# Example: bash /home_local/Nico/fmriTools/scripts/prepAtlases.sh 01 ses-01

# Default values
subj="01"
ses="ses-01"

# Parse command line options
while [[ $# -gt 0 ]]; do
  case $1 in
    --subject)
      subj="$2"
      shift 2
      ;;
    --session)
      ses="ses-$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Read variables from conf.yaml
programs_path=$(yq -r '.Paths.programs_path' conf.yaml)

# Read variables from analysis.yaml
base_data_path=$(yq -r '.base_data_path' analysis.yaml)
fs_subjects_dir=$(yq -r '.fs_subjects_dir' analysis.yaml)


# Set up FreeSurfer
export FREESURFER_HOME=${programs_path}/freesurfer
source $FREESURFER_HOME/SetUpFreeSurfer.sh

# Set FreeSurfer subjects directory
export SUBJECTS_DIR="${base_data_path}/${fs_subjects_dir}"

# Subject to process
subject_name="sub-${subj}_${ses}_iso"

# Step 1: Generate atlases using neuropythy
echo "Running atlas generation for ${subject_name} in SUBJECTS_DIR: ${SUBJECTS_DIR}"
python -m neuropythy atlas "${subject_name}"
echo "Completed atlas generation for ${subject_name}"

# Step 2: Convert .mgz to .curv for Benson and Wang
atlases_benson=('angle' 'eccen' 'sigma' 'varea')
atlases_wang=('mplbl')

subject_session_name="sub-${subj}_${ses}"
subject_fs_path="${base_data_path}/${fs_subjects_dir}/${subject_name}"
surf_atlas_path="${subject_fs_path}/surf"

echo "surf_atlas_path: $surf_atlas_path"

if [ -d "$surf_atlas_path" ]; then
  cd "$surf_atlas_path"
  echo "Converting files for ${subject_session_name}"

  for hemi in lh rh; do
    # Convert benson14 files (use relative path for sphere since we're in surf dir)
    for atlas in "${atlases_benson[@]}"; do
      mris_convert -c "${hemi}.benson14_${atlas}.mgz" "${hemi}.sphere" "${hemi}.benson14_${atlas}.curv"
    done

    # Convert wang15 files (use relative path for sphere since we're in surf dir)
    for atlas in "${atlases_wang[@]}"; do
      mris_convert -c "${hemi}.wang15_${atlas}.mgz" "${hemi}.sphere" "${hemi}.wang15.curv"
    done
  done

  echo "Completed conversions for ${subject_session_name}"
else
  echo "Surf directory not found for ${subject_session_name}"
fi

echo "Atlas preparation completed. You can now run roiMapper_test.py"