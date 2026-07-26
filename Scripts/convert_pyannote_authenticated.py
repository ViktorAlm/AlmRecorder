#!/usr/bin/env python3
"""
Convert Pyannote speaker embedding model to CoreML with proper authentication.

Steps:
1. Go to https://huggingface.co/pyannote/embedding and accept the conditions
2. Get your token from https://huggingface.co/settings/tokens
3. Run: HF_TOKEN="your_token_here" python convert_pyannote_authenticated.py
"""

import torch
import coremltools as ct
import numpy as np
import os
import sys

def convert_pyannote_to_coreml(hf_token):
    """Convert Pyannote embedding model to CoreML."""
    
    print("📦 Loading Pyannote embedding model...")
    
    try:
        # Set the token for HuggingFace
        from huggingface_hub import login
        login(token=hf_token)
        
        from pyannote.audio import Model
        
        # Load the pretrained model with authentication
        model = Model.from_pretrained("pyannote/embedding", use_auth_token=hf_token)
        model.eval()
        
        print("✅ Model loaded successfully")
        
    except Exception as e:
        print(f"❌ Error loading model: {e}")
        print("\nMake sure you have:")
        print("1. Accepted conditions at https://huggingface.co/pyannote/embedding")
        print("2. Used a valid token from https://huggingface.co/settings/tokens")
        return False
    
    print("🔄 Preparing model for CoreML conversion...")
    
    # The Pyannote embedding model expects:
    # Input: (batch_size, n_channels=1, n_samples)
    # Output: (batch_size, embedding_dim=512)
    
    # Create example input - 3 seconds of audio at 16kHz
    example_input = torch.randn(1, 1, 48000)
    
    print("🔄 Extracting the underlying model...")
    
    # The pyannote model is a PyTorch Lightning module
    # We need to extract the actual model for conversion
    
    # Set model to eval mode
    model.eval()
    
    print("🔄 Testing model forward pass...")
    
    # Test the model directly - it's already a callable model
    with torch.no_grad():
        test_output = model(example_input)
        print(f"✅ Model output shape: {test_output.shape}")
        print(f"   Embedding dimension: {test_output.shape[-1]}")
    
    print("🔄 Creating traced model for CoreML...")
    
    # Create a wrapper that properly handles the complete forward pass
    class EmbeddingModelWrapper(torch.nn.Module):
        def __init__(self, pyannote_model):
            super().__init__()
            self.model = pyannote_model
            
        def forward(self, x):
            # The model expects (batch, channel, time)
            # and returns (batch, embedding_dim)
            self.model.eval()
            with torch.no_grad():
                # Get the full embedding output
                output = self.model(x)
                return output
    
    # Create wrapped model
    wrapped_model = EmbeddingModelWrapper(model)
    wrapped_model.eval()
    
    # Trace the model
    with torch.no_grad():
        traced_model = torch.jit.trace(wrapped_model, example_input)
    
    print("🔄 Converting to CoreML...")
    
    try:
        # Convert to CoreML with flexible input size
        mlmodel = ct.convert(
            traced_model,
            inputs=[
                ct.TensorType(
                    name="audio_input",
                    shape=(1, 1, ct.RangeDim(16000, 160000)),  # 1-10 seconds of audio
                    dtype=np.float32
                )
            ],
            outputs=[
                ct.TensorType(
                    name="speaker_embedding",
                    dtype=np.float32
                )
            ],
            compute_units=ct.ComputeUnit.CPU_AND_NE,  # Use Neural Engine when available
            minimum_deployment_target=ct.target.macOS13
        )
        
        print("✅ Conversion successful")
        
    except Exception as e:
        print(f"❌ CoreML conversion failed: {e}")
        return False
    
    # Add metadata
    mlmodel.author = "Pyannote (Hervé Bredin)"
    mlmodel.license = "MIT"
    mlmodel.short_description = "Speaker embedding extraction model from Pyannote"
    mlmodel.version = "2.1"
    
    # Add input/output descriptions
    mlmodel.input_description["audio_input"] = "Audio waveform (1 channel, 16kHz, 1-10 seconds)"
    mlmodel.output_description["speaker_embedding"] = "512-dimensional speaker embedding vector"
    
    # Save the model
    output_dir = "../AlmRecorder/Resources/Models"
    os.makedirs(output_dir, exist_ok=True)
    
    model_path = os.path.join(output_dir, "PyannoteSpeakerEmbedding.mlpackage")
    mlmodel.save(model_path)
    
    print(f"✅ Model saved to: {model_path}")
    
    # Print model details
    spec = mlmodel.get_spec()
    print("\n📊 Model Details:")
    print(f"   Input: {spec.description.input[0].name}")
    print(f"   Input shape: (1, 1, 16000-160000)")
    print(f"   Output: {spec.description.output[0].name}")
    print(f"   Output shape: (1, 512)")
    
    # Get actual file size
    import subprocess
    result = subprocess.run(['du', '-sh', model_path], capture_output=True, text=True)
    if result.returncode == 0:
        size = result.stdout.split()[0]
        print(f"   Model size: {size}")
    
    return True

def verify_model(model_path):
    """Verify the converted CoreML model works correctly."""
    
    print("\n🧪 Verifying CoreML model...")
    
    try:
        # Load the CoreML model
        model = ct.models.MLModel(model_path)
        
        # Create test input (3 seconds at 16kHz)
        test_audio = np.random.randn(1, 1, 48000).astype(np.float32)
        
        # Make prediction
        prediction = model.predict({"audio_input": test_audio})
        
        embedding = prediction["speaker_embedding"]
        
        print(f"✅ Model verification successful")
        print(f"   Output shape: {embedding.shape}")
        print(f"   Embedding norm: {np.linalg.norm(embedding):.4f}")
        print(f"   Embedding mean: {np.mean(embedding):.4f}")
        print(f"   Embedding std: {np.std(embedding):.4f}")
        
        return True
        
    except Exception as e:
        print(f"❌ Verification failed: {e}")
        return False

def main():
    """Main conversion process."""
    
    print("🎙️ Pyannote to CoreML Converter for AlmRecorder")
    print("=" * 50)
    
    # Check for HuggingFace token
    hf_token = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN')
    
    if not hf_token:
        print("\n❌ No HuggingFace token found!")
        print("\nTo use the Pyannote model, you need to:")
        print("1. Go to https://huggingface.co/pyannote/embedding")
        print("2. Click 'Agree and access repository' to accept conditions")
        print("3. Get your token from https://huggingface.co/settings/tokens")
        print("4. Run this script with your token:")
        print("\n   HF_TOKEN=\"your_token_here\" python convert_pyannote_authenticated.py")
        print("\nAlternatively, login with huggingface-cli:")
        print("   huggingface-cli login")
        sys.exit(1)
    
    print(f"\n✅ Using HuggingFace token: {hf_token[:8]}...")
    
    # Check dependencies
    try:
        import pyannote.audio
        import torch
        import coremltools
        import huggingface_hub
    except ImportError as e:
        print(f"\n❌ Missing dependency: {e}")
        print("\nPlease install required packages:")
        print("pip install pyannote.audio torch coremltools huggingface-hub")
        sys.exit(1)
    
    # Convert model
    model_path = "../AlmRecorder/Resources/Models/PyannoteSpeakerEmbedding.mlpackage"
    
    if convert_pyannote_to_coreml(hf_token):
        # Verify the conversion
        if verify_model(model_path):
            print("\n✅ Success! Pyannote model ready for use in AlmRecorder")
            print("\nNext steps:")
            print("1. The model is saved at: AlmRecorder/Resources/Models/PyannoteSpeakerEmbedding.mlpackage")
            print("2. Add it to your Xcode project (drag into project navigator)")
            print("3. Ensure it's added to the AlmRecorder target")
            print("4. Build and run - speaker identification will work automatically!")
        else:
            print("\n⚠️ Model converted but verification failed")
    else:
        print("\n❌ Conversion failed")
        print("\nTroubleshooting:")
        print("1. Ensure you've accepted the model conditions at https://huggingface.co/pyannote/embedding")
        print("2. Verify your token has read access")
        print("3. Check your internet connection")
        sys.exit(1)

if __name__ == "__main__":
    main()