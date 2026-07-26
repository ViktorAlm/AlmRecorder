#!/usr/bin/env python3
"""
Simplified Pyannote to CoreML converter that handles the SincNet architecture.
Based on web search findings about handling PyTorch Lightning and custom layers.
"""

import torch
import coremltools as ct
import numpy as np
import os
import sys

def convert_pyannote_simplified(hf_token):
    """Convert Pyannote embedding model with simplified approach."""
    
    print("📦 Loading Pyannote embedding model...")
    
    try:
        from huggingface_hub import login
        login(token=hf_token)
        
        from pyannote.audio import Model
        
        # Load the model
        model = Model.from_pretrained("pyannote/embedding", use_auth_token=hf_token)
        model.eval()
        
        print("✅ Model loaded successfully")
        
    except Exception as e:
        print(f"❌ Error loading model: {e}")
        return False
    
    # Create example input - 3 seconds at 16kHz
    example_input = torch.randn(1, 1, 48000)
    
    # Test the model
    with torch.no_grad():
        output = model(example_input)
        print(f"✅ Model output shape: {output.shape}")
    
    print("🔄 Creating simplified model for conversion...")
    
    # Create a minimal wrapper that avoids PyTorch Lightning issues
    class MinimalEmbeddingModel(torch.nn.Module):
        def __init__(self, pyannote_model):
            super().__init__()
            # Store the model and ensure no gradients
            self.model = pyannote_model
            # Detach all parameters from gradient computation
            for param in self.model.parameters():
                param.requires_grad = False
            
        def forward(self, x):
            with torch.no_grad():
                return self.model(x)
    
    minimal_model = MinimalEmbeddingModel(model)
    minimal_model.eval()
    
    # Use torch.jit.trace with check_inputs for better error detection
    print("🔄 Tracing model...")
    
    try:
        # Create multiple test inputs for validation
        test_inputs = [
            torch.randn(1, 1, 16000),  # 1 second
            torch.randn(1, 1, 48000),  # 3 seconds  
            torch.randn(1, 1, 80000),  # 5 seconds
        ]
        
        # Trace with validation
        traced_model = torch.jit.trace(
            minimal_model, 
            example_input,
            check_inputs=[(t,) for t in test_inputs[:1]]  # Check with first test input
        )
        
        print("✅ Model traced successfully")
        
    except Exception as e:
        print(f"⚠️ Tracing with validation failed: {e}")
        print("🔄 Trying simple tracing...")
        
        # Fallback to simple tracing
        with torch.no_grad():
            traced_model = torch.jit.trace(minimal_model, example_input)
    
    print("🔄 Converting to CoreML...")
    
    # Try conversion with fixed input first
    try:
        # Convert with fixed size first (3 seconds)
        mlmodel = ct.convert(
            traced_model,
            convert_to="neuralnetwork",  # Use older format which is more compatible
            inputs=[
                ct.TensorType(
                    name="audio_input",
                    shape=(1, 1, 48000),  # Fixed 3-second input
                    dtype=np.float32
                )
            ],
            outputs=[
                ct.TensorType(
                    name="speaker_embedding",
                    dtype=np.float32
                )
            ],
            compute_units=ct.ComputeUnit.CPU_ONLY,  # Start with CPU only
            minimum_deployment_target=ct.target.macOS13
        )
        
        print("✅ Fixed-size conversion successful")
        
    except Exception as e:
        print(f"❌ CoreML conversion failed: {e}")
        print("\n🔄 Attempting alternative conversion approach...")
        
        # Try mlprogram format instead
        try:
            mlmodel = ct.convert(
                traced_model,
                convert_to="mlprogram",  # Newer format
                inputs=[
                    ct.TensorType(
                        name="audio_input",
                        shape=(1, 1, 48000),
                        dtype=np.float32
                    )
                ],
                compute_units=ct.ComputeUnit.CPU_ONLY
            )
            
            print("✅ MLProgram conversion successful")
            
        except Exception as e2:
            print(f"❌ Alternative conversion also failed: {e2}")
            return False
    
    # Add metadata
    mlmodel.author = "Pyannote (Hervé Bredin)"
    mlmodel.license = "MIT"
    mlmodel.short_description = "Speaker embedding extraction (fixed 3-second input)"
    mlmodel.version = "2.1"
    
    # Add descriptions
    if hasattr(mlmodel, 'input_description'):
        mlmodel.input_description["audio_input"] = "Audio waveform (1 channel, 16kHz, 3 seconds)"
    if hasattr(mlmodel, 'output_description'):
        mlmodel.output_description["speaker_embedding"] = "512-dimensional speaker embedding"
    
    # Save the model
    output_dir = "../AlmRecorder/Resources/Models"
    os.makedirs(output_dir, exist_ok=True)
    
    model_path = os.path.join(output_dir, "PyannoteSpeakerEmbedding.mlpackage")
    mlmodel.save(model_path)
    
    print(f"✅ Model saved to: {model_path}")
    
    # Verify the model
    print("\n🧪 Verifying CoreML model...")
    
    try:
        # Load and test
        loaded_model = ct.models.MLModel(model_path)
        
        # Test with fixed size
        test_audio = np.random.randn(1, 1, 48000).astype(np.float32)
        prediction = loaded_model.predict({"audio_input": test_audio})
        
        embedding = prediction.get("speaker_embedding", prediction.get("var_2457", None))
        if embedding is not None:
            print(f"✅ Model verification successful")
            print(f"   Output shape: {embedding.shape}")
            print(f"   Embedding norm: {np.linalg.norm(embedding):.4f}")
        else:
            print("⚠️ Model output key might be different, check output keys:")
            print(f"   Available keys: {list(prediction.keys())}")
        
    except Exception as e:
        print(f"❌ Verification failed: {e}")
    
    return True

def main():
    """Main conversion process."""
    
    print("🎙️ Pyannote to CoreML Converter (Simplified)")
    print("=" * 50)
    
    # Check for HuggingFace token
    hf_token = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN')
    
    if not hf_token:
        print("\n❌ No HuggingFace token found!")
        print("Please set: export HF_TOKEN='your_token_here'")
        sys.exit(1)
    
    print(f"\n✅ Using HuggingFace token: {hf_token[:8]}...")
    
    # Check dependencies
    try:
        import pyannote.audio
        import torch
        import coremltools
        print(f"📦 Using CoreML Tools version: {ct.__version__}")
        print(f"📦 Using PyTorch version: {torch.__version__}")
    except ImportError as e:
        print(f"\n❌ Missing dependency: {e}")
        sys.exit(1)
    
    # Convert model
    if convert_pyannote_simplified(hf_token):
        print("\n✅ Success! Pyannote model converted to CoreML")
        print("\nNote: This is a fixed-size model (3-second input)")
        print("For variable-size input, you'll need to:")
        print("1. Process audio in 3-second windows")
        print("2. Average embeddings for longer segments")
    else:
        print("\n❌ Conversion failed")
        print("\nTroubleshooting:")
        print("1. Try updating coremltools: pip install -U coremltools")
        print("2. Check PyTorch version compatibility")
        print("3. Consider using the alternative scripts")
        sys.exit(1)

if __name__ == "__main__":
    main()