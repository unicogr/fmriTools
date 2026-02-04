import os
import argparse
import pickle
import numpy as np
import nibabel as nib
import neuropythy as ny
import pandas as pd
import yaml
from pathlib import Path
import logging
import subprocess

# Set up logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

def load_config(config_path: str) -> dict:
    """Load configuration from YAML file."""
    logging.info(f"Loading config from {config_path}")
    if not Path(config_path).exists():
        logging.warning(f"Config file {config_path} not found. Using defaults.")
        return {
            'base_data_path': 'output',
            'derivatives_dir': 'derivatives/roi-mappings-test/',
            'fs_subjects_dir': 'fs_subjects',
            'surf_atlas_dir': 'surf',
            'roi_mappings': {
                'benson': {
                    "V1": 1, "V2": 2, "V3": 3, "hV4": 4, "VO1": 5, "VO2": 6,
                    "TO2": 7, "LO1": 8, "LO2": 9, "TO1": 10, "V3b": 11, "V3a": 12
                },
                'wang': {
                    "V1v": 1, "V1d": 2, "V2v": 3, "V2d": 4, "V3v": 5, "V3d": 6,
                    "hV4": 7, "VO1": 8, "VO2": 9, "PHC1": 10, "PHC2": 11,
                    "TO2": 12, "TO1": 13, "LO2": 14, "LO1": 15, "V3B": 16,
                    "V3A": 17, "IPS0": 18, "IPS1": 19, "IPS2": 20, "IPS3": 21,
                    "IPS4": 22, "IPS5": 23, "SPL1": 24, "FEF": 25
                }
            }
        }
    with open(config_path, 'r') as f:
        config = yaml.safe_load(f)
    # Make base_data_path absolute relative to config file
    config['base_data_path'] = str(Path(config_path).parent / config['base_data_path'])
    logging.info("Config loaded successfully")
    return config

def convert_wang_atlas(surf_atlas_path, h):
    """Convert Wang .mgz to .curv if needed."""
    mgz_file = Path(surf_atlas_path) / f'{h}.wang15_mplbl.mgz'
    curv_file = Path(surf_atlas_path) / f'{h}.wang15.curv'
    if mgz_file.exists() and not curv_file.exists():
        sphere_file = Path(surf_atlas_path).parent / f'{h}.sphere'
        subprocess.run(['mris_convert', '-c', str(mgz_file), str(sphere_file), str(curv_file)])
        logging.info(f"Converted Wang atlas for {h}")
    elif not mgz_file.exists():
        logging.warning(f"Wang .mgz file not found for {h}: {mgz_file}")

def compute_v1_centers_and_rights(fsaverage):
    """Compute V1 centers and rights from fsaverage."""
    logging.info("Computing V1 centers and rights from fsaverage")
    v1_centers = {}
    v1_rights = {}
    for h in ['lh', 'rh']:
        cortex = fsaverage.hemis[h]
        sphere = cortex.registrations['native']
        v1_weight = sphere.prop('V1_weight')
        coords = sphere.coordinates
        v1_center = np.sum(coords * v1_weight[None, :], axis=1) / np.sum(v1_weight)
        v1_centers[h] = v1_center
        
        weight = ~sphere.prop('cortex_label')
        mwall_center = np.mean(coords[:, weight], axis=1)
        v1_rights[h] = -mwall_center if h == 'rh' else mwall_center
    logging.info("V1 centers and rights computed")
    return v1_centers, v1_rights

def create_flatmaps(sub, v1_centers, v1_rights):
    """Create map projections and flatmaps."""
    logging.info("Creating flatmaps for subject")
    map_projs = {h: ny.map_projection(chirality=h, 
                                      center=v1_centers[h],
                                      center_right=v1_rights[h],
                                      method='orthographic',
                                      radius=np.pi/2,
                                      registration='native') 
                 for h in ['lh', 'rh']}
    flatmaps = {h: mp(sub.hemis[h]) for h, mp in map_projs.items()}
    logging.info("Flatmaps created")
    return flatmaps

def process_roi_data(flatmap, surf_atlas_path, h, config, output_dir):
    """Process ROI data for a hemisphere and save outputs."""
    logging.info(f"Processing ROI data for {h} hemisphere")
    cortex_index = flatmap.prop('index')
    
    roi_data = []
    atlas_data = {}
    
    # Load Benson atlas (always, for V1 distance and retinotopic data)
    logging.info(f"Loading Benson atlas for {h}")
    atlas_data['benson'] = {
        'varea_map': nib.freesurfer.io.read_morph_data(
            Path(surf_atlas_path) / f'{h}.benson14_varea.curv')[cortex_index],
        'sigma_map': nib.freesurfer.io.read_morph_data(
            Path(surf_atlas_path) / f'{h}.benson14_sigma.curv')[cortex_index],
        'eccen': nib.freesurfer.io.read_morph_data(
            Path(surf_atlas_path) / f'{h}.benson14_eccen.curv')[cortex_index],
        'polar': nib.freesurfer.io.read_morph_data(
            Path(surf_atlas_path) / f'{h}.benson14_angle.curv')[cortex_index]
    }
    
    # Load Wang atlas if available
    convert_wang_atlas(surf_atlas_path, h)
    wang_curv = Path(surf_atlas_path) / f'{h}.wang15.curv'
    if wang_curv.exists():
        logging.info(f"Loading Wang atlas for {h}")
        atlas_data['wang'] = {
            'varea_map': nib.freesurfer.io.read_morph_data(wang_curv)[cortex_index],
            'eccen': np.full_like(atlas_data['benson']['varea_map'], np.nan),
            'polar': np.full_like(atlas_data['benson']['varea_map'], np.nan),
            'sigma_map': np.full_like(atlas_data['benson']['varea_map'], np.nan)
        }
    else:
        logging.warning(f"Wang atlas not available for {h}, skipping Wang processing")
        atlas_data['wang'] = None
    
    # Process each atlas
    for atlas_type, data in atlas_data.items():
        if data is None:
            continue
        roi_name_to_index = config['roi_mappings'].get(atlas_type, {})
        logging.info(f"Processing {atlas_type} ROIs for {h}")
        
        # Handle V1 specifically (only for Benson, as Wang lacks retinotopic structure)
        if atlas_type == 'benson' and "V1" in roi_name_to_index:
            logging.info(f"Processing V1 for {h} ({atlas_type})")
            v1_index = roi_name_to_index["V1"]
            v1_mask = data['varea_map'] == v1_index
            v1_indices = np.where(v1_mask)[0]
            v1_original_indices = cortex_index[v1_indices]
            
            roi_submesh = flatmap.submesh(v1_mask)
            submesh_labels = roi_submesh.prop('label')
            
            logging.info(f"Computing distance matrix for V1 submesh in {h}...")
            distance_matrix = roi_submesh.dijkstra()
            
            v1_output_data = {
                'distance_matrix': distance_matrix,
                'global_indices': submesh_labels
            }
            v1_output_path = output_dir / f'v1_cortical_distances_{h}.pkl'
            with open(v1_output_path, 'wb') as f:
                pickle.dump(v1_output_data, f)
            logging.info(f"Saved V1 distances for {h} to {v1_output_path}")
            
            for i, orig_idx in enumerate(v1_original_indices):
                submesh_idx = np.where(submesh_labels == orig_idx)[0][0] if orig_idx in submesh_labels else np.nan
                roi_data.append({
                    'atlas': atlas_type,
                    'ROI': 'V1',
                    'vertex_index': orig_idx,
                    'submesh_index': submesh_idx,
                    'benson_eccen': data['eccen'][v1_indices[i]],
                    'benson_polar': data['polar'][v1_indices[i]],
                    'benson_sigma': data['sigma_map'][v1_indices[i]]
                })
        
        # Handle other ROIs
        for roi_name, roi_index in roi_name_to_index.items():
            if roi_name == "V1" and atlas_type == 'benson':
                continue  # Already handled
            roi_mask = data['varea_map'] == roi_index
            roi_indices = np.where(roi_mask)[0]
            roi_original_indices = cortex_index[roi_indices]
            for i, orig_idx in enumerate(roi_original_indices):
                roi_data.append({
                    'atlas': atlas_type,
                    'ROI': roi_name,
                    'vertex_index': orig_idx,
                    'submesh_index': np.nan,
                    'benson_eccen': data['eccen'][roi_indices[i]],
                    'benson_polar': data['polar'][roi_indices[i]],
                    'benson_sigma': data['sigma_map'][roi_indices[i]]
                })
    
    # Save dataframe
    df_roi = pd.DataFrame(roi_data)
    df_output_path = output_dir / f'roi_data_{h}.csv'
    df_roi.to_csv(df_output_path, index=False)
    logging.info(f"Saved ROI dataframe for {h} to {df_output_path}")

def main():
    logging.info("Starting ROI mapping script")
    parser = argparse.ArgumentParser(description='Process ROI data for a given subject.')
    parser.add_argument('--subject_id', type=str, required=True, help='Subject ID (e.g., 11)')
    parser.add_argument('--session_id', type=str, default='ses-01', help='Session ID (default: ses-01)')
    parser.add_argument('--config', type=str, default='analysis.yaml', help='Path to config YAML file')
    args = parser.parse_args()
    
    # Reconstruct config path relative to script location
    script_dir = Path(__file__).parent.parent
    config_path = script_dir / args.config
    
    logging.info(f"Processing subject {args.subject_id}, session {args.session_id}")
    config = load_config(str(config_path))
    base_data_path = Path(config['base_data_path'])
    derivatives_dir = base_data_path / config['derivatives_dir'] / f"sub-{args.subject_id}" / args.session_id
    derivatives_dir.mkdir(parents=True, exist_ok=True)
    logging.info(f"Output directory: {derivatives_dir}")
    
    fs_subject_path = base_data_path / config['fs_subjects_dir'] / f"sub-{args.subject_id}_{args.session_id}_iso"
    surf_atlas_path = fs_subject_path / config['surf_atlas_dir']
    logging.info(f"FreeSurfer subject path: {fs_subject_path}")
    logging.info(f"Surface atlas path: {surf_atlas_path}")
    
    # Load subjects
    logging.info("Loading FreeSurfer subjects")
    sub = ny.freesurfer_subject(str(fs_subject_path))
    fsaverage = ny.freesurfer_subject('fsaverage')
    
    # Compute V1 data
    v1_centers, v1_rights = compute_v1_centers_and_rights(fsaverage)
    
    # Create and save flatmaps
    flatmaps = create_flatmaps(sub, v1_centers, v1_rights)
    for h in ['lh', 'rh']:
        flatmap_output_path = derivatives_dir / f'flatmap_{h}.pkl'
        with open(flatmap_output_path, 'wb') as f:
            pickle.dump(flatmaps[h], f)
        logging.info(f"Saved flatmap for {h} to {flatmap_output_path}")
        
        # Process ROI data
        process_roi_data(flatmaps[h], surf_atlas_path, h, config, derivatives_dir)
    
    logging.info("ROI mapping completed successfully")

if __name__ == '__main__':
    main()