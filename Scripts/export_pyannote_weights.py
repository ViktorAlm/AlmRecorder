#!/usr/bin/env python3
"""
Export Pyannote model weights to a format we can use to build a custom CoreML model.
"""

import torch
import numpy as np
import os
import sys
import json

def export_pyannote_weights(hf_token):
    """Export Pyannote embedding model weights."""
    
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
        return False
    
    print("🔄 Analyzing model architecture...")
    
    # Test the model
    example_input = torch.randn(1, 1, 48000)
    with torch.no_grad():
        output = model(example_input)
        print(f"✅ Model output shape: {output.shape}")
    
    # Save the entire model as a PyTorch checkpoint
    output_dir = "../AlmRecorder/Resources/Models"
    os.makedirs(output_dir, exist_ok=True)
    
    # Save as TorchScript
    print("🔄 Creating TorchScript model...")
    
    # Create a simple wrapper that works with tracing
    class CleanEmbeddingModel(torch.nn.Module):
        def __init__(self, original_model):
            super().__init__()
            # Store the original model's forward method
            self.original_forward = original_model.forward
            # Copy necessary attributes
            self.model = original_model
            
        def forward(self, x):
            # Directly call the model without Lightning wrapper
            self.model.eval()
            return self.original_forward(x)
    
    clean_model = CleanEmbeddingModel(model)
    clean_model.eval()
    
    # Save as TorchScript
    with torch.no_grad():
        scripted = torch.jit.script(clean_model)
        torch.jit.save(scripted, os.path.join(output_dir, "pyannote_embedding.pt"))
    
    print(f"✅ TorchScript model saved")
    
    # Also save the raw state dict
    torch.save(model.state_dict(), os.path.join(output_dir, "pyannote_weights.pth"))
    print(f"✅ Model weights saved")
    
    # Save model info
    info = {
        "input_shape": [1, 1, 48000],
        "output_shape": list(output.shape),
        "architecture": "XVectorSincNet",
        "embedding_dim": 512
    }
    
    with open(os.path.join(output_dir, "model_info.json"), "w") as f:
        json.dump(info, f, indent=2)
    
    print(f"✅ Model info saved")
    
    return True

def main():
    """Main export process."""
    
    print("🎙️ Pyannote Model Weights Exporter")
    print("=" * 50)
    
    # Check for HuggingFace token
    hf_token = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN')
    
    if not hf_token:
        print("\n❌ No HuggingFace token found!")
        sys.exit(1)
    
    print(f"\n✅ Using HuggingFace token: {hf_token[:8]}...")
    
    # Export weights
    if export_pyannote_weights(hf_token):
        print("\n✅ Success! Model weights exported")
        print("\nNext steps:")
        print("1. Use create_coreml_from_weights.py to build CoreML model")
        print("2. Or use the TorchScript model directly with Metal Performance Shaders")
    else:
        print("\n❌ Export failed")
        sys.exit(1)

if __name__ == "__main__":
    main()