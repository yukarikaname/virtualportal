#!/usr/bin/env python3
"""
Motion Learning Training Script

Trains motion learning models from motion capture data and saves them
for use in the virtualportal app.

Usage:
    python scripts/train.py --input <motion_data_dir> --output <model_dir> --epochs 50
    python scripts/train.py --help
"""

import argparse
import json
import numpy as np
import torch
import torch.nn as nn
from torch.utils.data import Dataset, DataLoader
from pathlib import Path
import pickle
from typing import Dict, List, Tuple, Optional
from dataclasses import dataclass
import logging

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# MARK: - Data Structures

@dataclass
class MotionData:
    """Represents a single motion sequence"""
    name: str
    frames: np.ndarray  # Shape: (num_frames, num_bones, 7) - 3 pos + 4 quat
    bone_names: List[str]
    framerate: float = 30.0
    
    @property
    def duration(self) -> float:
        return len(self.frames) / self.framerate
    
    @property
    def num_frames(self) -> int:
        return len(self.frames)


@dataclass
class TrainingConfig:
    """Training hyperparameters"""
    learning_rate: float = 0.001
    batch_size: int = 32
    epochs: int = 50
    hidden_dim: int = 256
    latent_dim: int = 128
    dropout: float = 0.2
    device: str = "cuda" if torch.cuda.is_available() else "cpu"
    checkpoint_interval: int = 10


# MARK: - Motion Encoder/Decoder

class MotionEncoder(nn.Module):
    """Encodes motion sequences to latent space"""
    
    def __init__(self, input_dim: int, hidden_dim: int, latent_dim: int, dropout: float = 0.2):
        super().__init__()
        self.encoder = nn.Sequential(
            nn.Linear(input_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, latent_dim)
        )
    
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.encoder(x)


class MotionDecoder(nn.Module):
    """Decodes latent space back to motion sequences"""
    
    def __init__(self, latent_dim: int, hidden_dim: int, output_dim: int, dropout: float = 0.2):
        super().__init__()
        self.decoder = nn.Sequential(
            nn.Linear(latent_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, output_dim)
        )
    
    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return self.decoder(x)


class MotionAutoencoder(nn.Module):
    """Autoencoder for motion compression and variation generation"""
    
    def __init__(self, motion_dim: int, config: TrainingConfig):
        super().__init__()
        self.encoder = MotionEncoder(
            motion_dim, config.hidden_dim, config.latent_dim, config.dropout
        )
        self.decoder = MotionDecoder(
            config.latent_dim, config.hidden_dim, motion_dim, config.dropout
        )
    
    def forward(self, x: torch.Tensor) -> Tuple[torch.Tensor, torch.Tensor]:
        latent = self.encoder(x)
        reconstructed = self.decoder(latent)
        return reconstructed, latent


# MARK: - Dataset

class MotionDataset(Dataset):
    """PyTorch Dataset for motion sequences"""
    
    def __init__(self, motions: List[MotionData], normalize: bool = True):
        self.motions = motions
        self.normalize = normalize
        
        # Flatten motion frames for training
        frame_list: List[np.ndarray] = []
        self.motion_indices: List[int] = []
        
        for motion_idx, motion in enumerate(motions):
            for frame in motion.frames:
                frame_list.append(frame.flatten())
                self.motion_indices.append(motion_idx)
        
        self.frames: np.ndarray = np.array(frame_list)
        
        # Normalize to [-1, 1]
        if normalize:
            self.mean = np.mean(self.frames, axis=0)
            self.std = np.std(self.frames, axis=0) + 1e-6
            self.frames = (self.frames - self.mean) / self.std
    
    def __len__(self) -> int:
        return len(self.frames)
    
    def __getitem__(self, idx: int) -> Tuple[torch.Tensor, int]:
        return (
            torch.FloatTensor(self.frames[idx]),
            self.motion_indices[idx]
        )
    
    def denormalize(self, frames: np.ndarray) -> np.ndarray:
        """Convert normalized frames back to original scale"""
        if self.normalize:
            return frames * self.std + self.mean
        return frames


# MARK: - Training

class MotionTrainer:
    """Trains motion autoencoder"""
    
    def __init__(self, config: TrainingConfig):
        self.config = config
        self.device = torch.device(config.device)
        self.best_loss = float('inf')
    
    def train(
        self,
        model: MotionAutoencoder,
        train_loader: DataLoader,
        val_loader: Optional[DataLoader] = None,
        save_dir: Optional[Path] = None
    ) -> Dict[str, List[float]]:
        """Train the motion autoencoder"""
        
        optimizer = torch.optim.Adam(model.parameters(), lr=self.config.learning_rate)
        criterion = nn.MSELoss()
        model = model.to(self.device)
        
        history = {'train_loss': [], 'val_loss': []}
        
        for epoch in range(self.config.epochs):
            # Training
            train_loss = self._train_epoch(model, train_loader, optimizer, criterion)
            history['train_loss'].append(train_loss)
            
            # Validation
            if val_loader is not None:
                val_loss = self._validate(model, val_loader, criterion)
                history['val_loss'].append(val_loss)
                
                # Save best model
                if val_loss < self.best_loss:
                    self.best_loss = val_loss
                    if save_dir:
                        self._save_checkpoint(model, save_dir, epoch, val_loss)
                
                logger.info(
                    f"Epoch {epoch+1}/{self.config.epochs} - "
                    f"Train Loss: {train_loss:.6f}, Val Loss: {val_loss:.6f}"
                )
            else:
                logger.info(f"Epoch {epoch+1}/{self.config.epochs} - Train Loss: {train_loss:.6f}")
            
            # Checkpoint
            if (epoch + 1) % self.config.checkpoint_interval == 0 and save_dir:
                self._save_checkpoint(model, save_dir, epoch, train_loss)
        
        return history
    
    def _train_epoch(
        self,
        model: MotionAutoencoder,
        train_loader: DataLoader,
        optimizer: torch.optim.Optimizer,
        criterion: nn.MSELoss
    ) -> float:
        """Train for one epoch"""
        model.train()
        total_loss = 0
        
        for batch_idx, (frames, _) in enumerate(train_loader):
            frames = frames.to(self.device)
            
            optimizer.zero_grad()
            reconstructed, _ = model(frames)
            loss = criterion(reconstructed, frames)
            
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=1.0)
            optimizer.step()
            
            total_loss += loss.item()
        
        return total_loss / len(train_loader)
    
    def _validate(
        self,
        model: MotionAutoencoder,
        val_loader: DataLoader,
        criterion: nn.MSELoss
    ) -> float:
        """Validate the model"""
        model.eval()
        total_loss = 0
        
        with torch.no_grad():
            for frames, _ in val_loader:
                frames = frames.to(self.device)
                reconstructed, _ = model(frames)
                loss = criterion(reconstructed, frames)
                total_loss += loss.item()
        
        return total_loss / len(val_loader)
    
    def _save_checkpoint(self, model: MotionAutoencoder, save_dir: Path, epoch: int, loss: float):
        """Save model checkpoint"""
        save_dir.mkdir(parents=True, exist_ok=True)
        
        checkpoint_path = save_dir / f"model_epoch_{epoch+1}.pt"
        torch.save({
            'epoch': epoch,
            'model_state_dict': model.state_dict(),
            'loss': loss
        }, checkpoint_path)
        
        logger.info(f"Saved checkpoint: {checkpoint_path}")


# MARK: - Data Loading

def load_motion_data(data_dir: Path) -> List[MotionData]:
    """Load motion data from JSON files"""
    motions = []
    
    if not data_dir.exists():
        logger.warning(f"Data directory not found: {data_dir}")
        return motions
    
    for json_file in sorted(data_dir.glob("*.json")):
        try:
            with open(json_file, 'r') as f:
                data = json.load(f)
            
            motion = MotionData(
                name=data['name'],
                frames=np.array(data['frames']),
                bone_names=data.get('bone_names', []),
                framerate=data.get('framerate', 30.0)
            )
            motions.append(motion)
            logger.info(f"Loaded motion: {motion.name} ({motion.num_frames} frames)")
        
        except Exception as e:
            logger.error(f"Error loading {json_file}: {e}")
    
    return motions


def save_trained_model(
    model: MotionAutoencoder,
    dataset: MotionDataset,
    output_dir: Path,
    motions: List[MotionData]
):
    """Save trained model for app use"""
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Save model
    model_path = output_dir / "motion_model.pt"
    torch.save(model.state_dict(), model_path)
    logger.info(f"Saved model: {model_path}")
    
    # Save metadata
    metadata = {
        'motion_names': [m.name for m in motions],
        'num_bones': len(motions[0].bone_names) if motions else 0,
        'bone_names': motions[0].bone_names if motions else [],
        'framerate': motions[0].framerate if motions else 30.0,
        'normalize_mean': dataset.mean.tolist(),
        'normalize_std': dataset.std.tolist(),
        'config': {
            'learning_rate': dataset.mean.shape[0],  # Input dimension
            'hidden_dim': model.encoder.encoder[0].out_features,
            'latent_dim': model.encoder.encoder[-1].out_features
        }
    }
    
    metadata_path = output_dir / "motion_metadata.json"
    with open(metadata_path, 'w') as f:
        json.dump(metadata, f, indent=2)
    logger.info(f"Saved metadata: {metadata_path}")
    
    # Save normalization parameters
    norm_path = output_dir / "normalization.pkl"
    with open(norm_path, 'wb') as f:
        pickle.dump({
            'mean': dataset.mean,
            'std': dataset.std
        }, f)
    logger.info(f"Saved normalization: {norm_path}")


def create_sample_motion_data(output_dir: Path):
    """Create sample motion data for testing"""
    output_dir.mkdir(parents=True, exist_ok=True)
    
    # Define sample motions
    motions_data = {
        'wave': {
            'name': 'wave',
            'bone_names': [
                'Armature.RightShoulder', 'Armature.RightElbow', 'Armature.RightWrist',
                'Armature.LeftShoulder', 'Armature.LeftElbow', 'Armature.LeftWrist',
                'Armature.Head', 'Armature.Spine'
            ],
            'framerate': 30.0
        },
        'spin': {
            'name': 'spin',
            'bone_names': [
                'Armature.RightShoulder', 'Armature.RightElbow', 'Armature.RightWrist',
                'Armature.LeftShoulder', 'Armature.LeftElbow', 'Armature.LeftWrist',
                'Armature.Head', 'Armature.Spine'
            ],
            'framerate': 30.0
        }
    }
    
    # Generate synthetic motion data (sine waves with different patterns)
    for motion_name, motion_info in motions_data.items():
        num_frames = 60  # 2 seconds at 30fps
        num_bones = len(motion_info['bone_names'])
        
        # Create synthetic motion data
        # Each bone has: [px, py, pz, qx, qy, qz, qw]
        frames = []
        for frame_idx in range(num_frames):
            frame = []
            for bone_idx in range(num_bones):
                # Sine wave motion with different frequencies per bone
                phase = 2 * np.pi * frame_idx / num_frames
                freq = 1.0 + bone_idx * 0.1
                
                # Position (3D)
                px = np.sin(phase * freq) * 0.1
                py = np.cos(phase * freq) * 0.05
                pz = np.sin(phase * freq * 0.5) * 0.05
                
                # Rotation (quaternion - normalized)
                qx = np.sin(phase * freq * 0.5) * 0.3
                qy = np.cos(phase * freq * 0.5) * 0.3
                qz = np.sin(phase * freq) * 0.2
                qw = np.sqrt(max(0, 1 - qx**2 - qy**2 - qz**2))  # Normalize
                
                frame.extend([px, py, pz, qx, qy, qz, qw])
            
            frames.append(frame)
        
        # Save motion data
        motion_json = {
            'name': motion_name,
            'bone_names': motion_info['bone_names'],
            'framerate': motion_info['framerate'],
            'frames': frames
        }
        
        output_file = output_dir / f"{motion_name}.json"
        with open(output_file, 'w') as f:
            json.dump(motion_json, f)
        
        logger.info(f"Created sample motion: {output_file}")


# MARK: - Main

def main():
    parser = argparse.ArgumentParser(description='Train motion learning model')
    parser.add_argument('--input', type=Path, default=Path('data/motions'),
                        help='Input motion data directory')
    parser.add_argument('--output', type=Path, default=Path('models/motion_model'),
                        help='Output model directory')
    parser.add_argument('--epochs', type=int, default=50,
                        help='Number of training epochs')
    parser.add_argument('--batch-size', type=int, default=32,
                        help='Batch size for training')
    parser.add_argument('--learning-rate', type=float, default=0.001,
                        help='Learning rate')
    parser.add_argument('--hidden-dim', type=int, default=256,
                        help='Hidden dimension size')
    parser.add_argument('--latent-dim', type=int, default=128,
                        help='Latent dimension size')
    parser.add_argument('--create-sample', action='store_true',
                        help='Create sample motion data for testing')
    parser.add_argument('--device', type=str, default='cuda' if torch.cuda.is_available() else 'cpu',
                        help='Device to use (cuda or cpu)')
    
    args = parser.parse_args()
    
    logger.info("=" * 60)
    logger.info("Motion Learning Training")
    logger.info("=" * 60)
    
    # Create sample data if requested
    if args.create_sample:
        logger.info("Creating sample motion data...")
        create_sample_motion_data(args.input)
    
    # Load motion data
    logger.info(f"Loading motion data from {args.input}...")
    motions = load_motion_data(args.input)
    
    if not motions:
        logger.error("No motion data found. Use --create-sample to generate test data.")
        return
    
    # Prepare dataset
    logger.info("Preparing dataset...")
    dataset = MotionDataset(motions, normalize=True)
    dataloader = DataLoader(dataset, batch_size=args.batch_size, shuffle=True)
    
    # Create and train model
    motion_dim = dataset.frames.shape[1]
    config = TrainingConfig(
        learning_rate=args.learning_rate,
        batch_size=args.batch_size,
        epochs=args.epochs,
        hidden_dim=args.hidden_dim,
        latent_dim=args.latent_dim,
        device=args.device
    )
    
    logger.info(f"Creating model with motion_dim={motion_dim}, latent_dim={args.latent_dim}")
    model = MotionAutoencoder(motion_dim, config)
    
    logger.info("Starting training...")
    trainer = MotionTrainer(config)
    trainer.train(model, dataloader, save_dir=args.output)
    
    # Save trained model
    logger.info("Saving trained model...")
    save_trained_model(model, dataset, args.output, motions)
    
    logger.info("=" * 60)
    logger.info("Training complete!")
    logger.info(f"Model saved to: {args.output}")
    logger.info("=" * 60)


if __name__ == '__main__':
    main()