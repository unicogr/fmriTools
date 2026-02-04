import os
import argparse
import pickle
import numpy as np
import pandas as pd
import nibabel as nib
from nilearn import signal
import yaml
from pathlib import Path
import logging

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
            'tasks': ['LPP1', 'LPP2', 'LPP3', 'LPP4', 'LPP5', 'LPP6', 'LPP7', 'LPP8', 'LOCA'],
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

def _safe_get_zooms(header) -> tuple:
    """Best-effort retrieval of voxel zooms from a nibabel header."""
    try:
        zooms = header.get_zooms()
        if zooms:
            return tuple(zooms)
    except Exception:
        pass

    try:
        pixdim = header.get('pixdim')
        if pixdim is not None:
            pixdim_arr = np.array(pixdim).squeeze()
            return tuple(pixdim_arr.tolist())
    except Exception:
        pass

    return tuple()

def extract_tr_and_frames(img_or_path):
    """Attempt to extract TR (seconds) and number of frames from an image header."""
    if isinstance(img_or_path, (str, os.PathLike)):
        img = nib.load(str(img_or_path))
    else:
        img = img_or_path

    hdr = img.header

    shape = img.shape
    n_frames = int(shape[3]) if len(shape) > 3 else 1

    tr_seconds = None

    zooms = _safe_get_zooms(hdr)
    if len(zooms) > 3:
        tzoom = float(zooms[3])
    else:
        tzoom = np.nan

    time_unit = None
    try:
        xyzt = hdr.get_xyzt_units()
        if isinstance(xyzt, tuple) and len(xyzt) >= 2:
            time_unit = xyzt[1]
    except Exception:
        time_unit = None

    if not np.isnan(tzoom):
        if time_unit and str(time_unit).lower().startswith('m'):
            tr_seconds = float(tzoom) / 1000.0
        elif time_unit and str(time_unit).lower().startswith('s'):
            tr_seconds = float(tzoom)
        else:
            try:
                if tzoom >= 100:
                    tr_seconds = float(tzoom) / 1000.0
                else:
                    tr_seconds = float(tzoom)
            except Exception:
                tr_seconds = None

    if tr_seconds is None:
        for key in ('tr', 'repetition_time', 'repetitiontime'):
            try:
                value = hdr.get(key)
            except Exception:
                continue
            if value is None:
                continue
            try:
                numeric_value = float(np.array(value).squeeze())
            except Exception:
                continue
            tr_seconds = numeric_value / 1000.0 if numeric_value >= 100 else numeric_value
            break

    if tr_seconds is not None:
        try:
            if not np.isfinite(tr_seconds) or tr_seconds <= 0:
                tr_seconds = None
        except Exception:
            tr_seconds = None

    return tr_seconds, n_frames

def main():
    parser = argparse.ArgumentParser(description='Extract time series for specified ROIs from surface-projected data.')
    parser.add_argument('--subject_id', type=str, required=True, help='Subject ID (e.g., 01)')
    parser.add_argument('--session_id', type=str, default='ses-01', help='Session ID (default: ses-01)')
    parser.add_argument('--config', type=str, default='analysis.yaml', help='Path to analysis config YAML file')
    parser.add_argument('--atlas', type=str, default='benson', choices=['benson', 'wang'], help='Atlas to use (default: benson)')
    parser.add_argument('--rois', nargs='+', default=['V1', 'V2', 'V3'], help='List of ROIs to extract (default: V1 V2 V3)')
    parser.add_argument('--tasks', nargs='+', help='List of tasks to process (default: all from analysis.yaml)')
    parser.add_argument('--high_pass', type=float, default=0.006, help='High-pass filter frequency (Hz), default 0.006')
    args = parser.parse_args()

    # Reconstruct config path relative to script location
    script_dir = Path(__file__).parent.parent
    config_path = script_dir / args.config

    logging.info(f"Processing subject {args.subject_id}, session {args.session_id}")
    config = load_config(str(config_path))
    tasks = config.get('tasks', [])
    if args.tasks is None:
        args.tasks = tasks

    base_data_path = Path(config['base_data_path'])
    derivatives_dir = base_data_path / config['derivatives_dir'] / f"sub-{args.subject_id}" / args.session_id
    surf_projected_path = base_data_path / 'derivatives/surf-projected' / f"sub-{args.subject_id}" / args.session_id / 'func'

    roi_mappings = config['roi_mappings'].get(args.atlas, {})

    # Process each hemisphere
    for h in ['lh', 'rh']:
        logging.info(f"Processing hemisphere: {h}")
        
        # Load existing ROI dataframe
        df_output_path = derivatives_dir / f'roi_data_{h}.csv'
        if not df_output_path.exists():
            logging.warning(f"ROI dataframe not found for {h}: {df_output_path}")
            continue
        df_roi = pd.read_csv(df_output_path)
        
        # Filter for selected atlas
        df_roi_atlas = df_roi[df_roi['atlas'] == args.atlas] if 'atlas' in df_roi.columns else df_roi
        
        # Extract vertices for selected ROIs
        roi_timeseries = {}
        for roi in args.rois:
            if roi in roi_mappings:
                roi_mask = df_roi_atlas['ROI'] == roi
                roi_vertices = df_roi_atlas.loc[roi_mask, 'vertex_index'].values.astype(int)
                roi_timeseries[roi] = {'vertices': roi_vertices}
        
        # Process each task
        for task in args.tasks:
            # Assuming task names map to file suffixes; adjust as needed
            task_suffix = f'_task-{task}_desc-surf'
            func_file = f"{h}.sub-{args.subject_id}_{args.session_id}{task_suffix}.mgh"
            func_path = surf_projected_path / func_file
            if not func_path.exists():
                logging.warning(f"Skipping {task} for {h}: file not found {func_path}")
                continue
            
            logging.info(f"Processing {task} for {h}")
            img = nib.load(str(func_path))
            effective_tr, n_frames = extract_tr_and_frames(img)
            if effective_tr is None:
                logging.warning(f"Could not detect TR for {func_file}, using default 2.0s")
                effective_tr = 2.0
            logging.info(f"  Detected TR: {effective_tr:.6f} s, Frames: {n_frames}")
            
            time_series = np.squeeze(img.get_fdata())  # Shape: (n_vertices, n_timepoints)
            
            # Clean the time series
            clean_kwargs = {
                'confounds': None,
                'detrend': True,
                'standardize': 'psc',
                'filter': 'butterworth',
                'high_pass': args.high_pass,
                'tr': effective_tr
            }
            time_series_cleaned = signal.clean(time_series.T, **clean_kwargs).T
            
            # Extract for each ROI
            for roi in args.rois:
                if roi in roi_timeseries:
                    roi_vertices = roi_timeseries[roi]['vertices']
                    roi_ts = time_series_cleaned[roi_vertices, :]
                    if task not in roi_timeseries[roi]:
                        roi_timeseries[roi][task] = []
                    roi_timeseries[roi][task].append(roi_ts)
        
        # Save time series
        ts_output_path = derivatives_dir / f'timeseries_{args.atlas}_{h}.pkl'
        with open(ts_output_path, 'wb') as f:
            pickle.dump(roi_timeseries, f)
        logging.info(f"Saved time series for {h} to {ts_output_path}")
        # Log summary
        processed_tasks = set()
        for roi in roi_timeseries:
            for task in roi_timeseries[roi]:
                if task != 'vertices':
                    processed_tasks.add(task)
        logging.info(f"Processed {len(processed_tasks)} tasks for {h}: {sorted(processed_tasks)}")

if __name__ == '__main__':
    main()