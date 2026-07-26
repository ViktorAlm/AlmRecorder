#!/usr/bin/env python3
"""
Convert Pyannote speaker embedding model to CoreML format
for use in AlmRecorder Swift application.

Requirements:
- pip install pyannote.audio torch coremltools

Usage:
    python convert_pyannote_to_coreml.py
"""

import torch
import coremltools as ct
import numpy as np
import os
import sys

def download_and_convert_pyannote():
    """Download Pyannote embedding model and convert to CoreML."""
    
    print("📦 Loading Pyannote embedding model...")
    print("")
    print("NOTE: The pyannote/embedding model requires authentication.")
    print("Please visit https://hf.co/pyannote/embedding to accept conditions.")
    print("Then get your token from https://hf.co/settings/tokens")
    print("")
    
    # Check for HuggingFace token in environment
    import os
    hf_token = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN')
    
    if not hf_token:
        print("Please set your HuggingFace token:")
        print("export HF_TOKEN='your_token_here'")
        print("")
        print("Or login with huggingface-cli:")
        print("huggingface-cli login")
        print("")
        return False
    
    try:
        from pyannote.audio import Model
        
        # Load the pretrained model with authentication
        try:
            model = Model.from_pretrained("pyannote/embedding", use_auth_token=hf_token)
        except:
            model = Model.from_pretrained("pyannote/embedding")
            
        model.eval()
        
        print("✅ Model loaded successfully")
        
    except ImportError:
        print("❌ Error: pyannote.audio not installed")
        print("Please run: pip install pyannote.audio")
        return False
    except Exception as e:
        print(f"❌ Error loading model: {e}")
        return False
    
    print("🔄 Tracing model for CoreML conversion...")
    
    # Create example input - 3 seconds of audio at 16kHz
    # Shape: (batch_size=1, channels=1, samples=48000)
    example_input = torch.randn(1, 1, 48000)
    
    # Trace the model
    with torch.no_grad():
        traced_model = torch.jit.trace(model, example_input)
        
        # Test the traced model
        test_output = traced_model(example_input)
        print(f"✅ Model output shape: {test_output.shape}")
        print(f"   Embedding dimension: {test_output.shape[-1]}")
    
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
    mlmodel.author = "Pyannote (via AlmRecorder)"
    mlmodel.license = "MIT"
    mlmodel.short_description = "Speaker embedding extraction model from Pyannote"
    mlmodel.version = "1.0"
    
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
    print(f"   Model size: ~{os.path.getsize(model_path) / 1024 / 1024:.1f} MB")
    
    return True

def verify_model():
    """Verify the converted CoreML model works correctly."""
    
    print("\n🧪 Verifying CoreML model...")
    
    import coremltools as ct
    
    model_path = "../AlmRecorder/Resources/Models/PyannoteSpeakerEmbedding.mlpackage"
    
    if not os.path.exists(model_path):
        print("❌ Model file not found")
        return False
    
    try:
        # Load the CoreML model
        model = ct.models.MLModel(model_path)
        
        # Create test input
        test_audio = np.random.randn(1, 1, 48000).astype(np.float32)
        
        # Make prediction
        prediction = model.predict({"audio_input": test_audio})
        
        embedding = prediction["speaker_embedding"]
        
        print(f"✅ Model verification successful")
        print(f"   Output shape: {embedding.shape}")
        print(f"   Embedding min: {np.min(embedding):.4f}")
        print(f"   Embedding max: {np.max(embedding):.4f}")
        print(f"   Embedding mean: {np.mean(embedding):.4f}")
        
        return True
        
    except Exception as e:
        print(f"❌ Verification failed: {e}")
        return False

def download_preconverted_model():
    """Download a pre-converted CoreML model as fallback."""
    
    print("\n📥 Downloading pre-converted speaker embedding model...")
    
    import urllib.request
    import zipfile
    
    # URL to a pre-converted model (we would host this)
    model_url = "https://github.com/YOUR_REPO/releases/download/v1.0/PyannoteSpeakerEmbedding.mlpackage.zip"
    
    output_dir = "../AlmRecorder/Resources/Models"
    os.makedirs(output_dir, exist_ok=True)
    
    try:
        # For now, create a dummy model for testing
        print("⚠️ Pre-converted model not available yet.")
        print("Please either:")
        print("1. Provide HuggingFace token to convert the model")
        print("2. Use the included test model")
        
        # Create a simple test model as placeholder
        create_dummy_model()
        return True
        
    except Exception as e:
        print(f"❌ Download failed: {e}")
        return False

def create_dummy_model():
    """Create a dummy CoreML model for testing."""
    print("\n🔧 Creating test speaker embedding model...")
    
    import coremltools as ct
    from coremltools.models.neural_network import NeuralNetworkBuilder
    import numpy as np
    
    # Create a simple neural network that outputs 512-dim embeddings
    input_features = [("audio_input", ct.models.datatypes.Array(1, 1, 48000))]
    output_features = [("speaker_embedding", ct.models.datatypes.Array(512))]
    
    builder = NeuralNetworkBuilder(input_features, output_features)
    
    # Add a simple layer to produce 512-dim output
    builder.add_inner_product(
        name="embedding_layer",
        input_name="audio_input",
        output_name="speaker_embedding",
        input_channels=48000,
        output_channels=512,
        W=np.random.randn(512, 48000).astype(np.float32) * 0.01,
        b=np.zeros(512, dtype=np.float32)
    )
    
    # Create the model
    mlmodel = ct.models.MLModel(builder.spec)
    
    # Add metadata
    mlmodel.author = "AlmRecorder Test"
    mlmodel.short_description = "Test speaker embedding model (not functional)"
    mlmodel.version = "0.1"
    
    # Save
    output_dir = "../AlmRecorder/Resources/Models"
    os.makedirs(output_dir, exist_ok=True)
    
    model_path = os.path.join(output_dir, "PyannoteSpeakerEmbedding.mlpackage")
    mlmodel.save(model_path)
    
    print(f"✅ Test model saved to: {model_path}")
    print("⚠️ Note: This is a non-functional test model for development only.")
    
def main():
    """Main conversion process."""
    
    print("🎙️ Pyannote to CoreML Converter for AlmRecorder")
    print("=" * 50)
    
    # Check dependencies
    try:
        import pyannote.audio
        import torch
        import coremltools
    except ImportError as e:
        print(f"❌ Missing dependency: {e}")
        print("\nPlease install required packages:")
        print("pip install pyannote.audio torch coremltools")
        sys.exit(1)
    
    # Convert model
    if download_and_convert_pyannote():
        # Verify the conversion
        if verify_model():
            print("\n✅ Success! Model ready for use in AlmRecorder")
            print("\nNext steps:")
            print("1. Add PyannoteSpeakerEmbedding.mlpackage to Xcode project")
            print("2. Use PyannoteSpeakerEmbedding class in Swift")
        else:
            print("\n⚠️ Model converted but verification failed")
    else:
        print("\n❌ Conversion failed")
        sys.exit(1)

if __name__ == "__main__":
    main()