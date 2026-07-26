#!/usr/bin/env python3
"""
Convert Pyannote speaker embedding model to CoreML via ONNX.
This approach avoids direct PyTorch to CoreML conversion issues.
"""

import torch
import coremltools as ct
import numpy as np
import os
import sys

def convert_pyannote_via_onnx(hf_token):
    """Convert Pyannote embedding model to CoreML via ONNX."""
    
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
    
    print("🔄 Exporting to ONNX...")
    
    # Create example input
    example_input = torch.randn(1, 1, 48000)
    
    # Export to ONNX
    onnx_path = "pyannote_embedding.onnx"
    
    try:
        torch.onnx.export(
            model,
            example_input,
            onnx_path,
            export_params=True,
            opset_version=12,
            do_constant_folding=True,
            input_names=['audio_input'],
            output_names=['speaker_embedding'],
            dynamic_axes={
                'audio_input': {2: 'audio_length'},
            }
        )
        
        print(f"✅ ONNX export successful: {onnx_path}")
        
    except Exception as e:
        print(f"❌ ONNX export failed: {e}")
        return False
    
    print("🔄 Converting ONNX to CoreML...")
    
    try:
        # Convert ONNX to CoreML
        mlmodel = ct.converters.onnx.convert(
            model=onnx_path,
            minimum_ios_deployment_target='15.0',
            compute_units=ct.ComputeUnit.CPU_AND_NE
        )
        
        print("✅ CoreML conversion successful")
        
    except Exception as e:
        print(f"❌ CoreML conversion failed: {e}")
        # Try alternative conversion with fixed input size
        print("🔄 Trying fixed-size conversion...")
        
        try:
            # Re-export ONNX with fixed size
            torch.onnx.export(
                model,
                example_input,
                onnx_path,
                export_params=True,
                opset_version=12,
                do_constant_folding=True,
                input_names=['audio_input'],
                output_names=['speaker_embedding']
            )
            
            mlmodel = ct.converters.onnx.convert(
                model=onnx_path,
                minimum_ios_deployment_target='15.0',
                compute_units=ct.ComputeUnit.CPU_AND_NE
            )
            
            print("✅ Fixed-size conversion successful")
            
        except Exception as e2:
            print(f"❌ Fixed-size conversion also failed: {e2}")
            return False
    
    # Add metadata
    mlmodel.author = "Pyannote (Hervé Bredin)"
    mlmodel.license = "MIT"
    mlmodel.short_description = "Speaker embedding extraction model from Pyannote"
    mlmodel.version = "2.1"
    
    # Save the model
    output_dir = "../AlmRecorder/Resources/Models"
    os.makedirs(output_dir, exist_ok=True)
    
    model_path = os.path.join(output_dir, "PyannoteSpeakerEmbedding.mlpackage")
    mlmodel.save(model_path)
    
    print(f"✅ Model saved to: {model_path}")
    
    # Clean up ONNX file
    if os.path.exists(onnx_path):
        os.remove(onnx_path)
    
    return True

def main():
    """Main conversion process."""
    
    print("🎙️ Pyannote to CoreML Converter (via ONNX)")
    print("=" * 50)
    
    # Check for HuggingFace token
    hf_token = os.environ.get('HF_TOKEN') or os.environ.get('HUGGING_FACE_HUB_TOKEN')
    
    if not hf_token:
        print("\n❌ No HuggingFace token found!")
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
        sys.exit(1)
    
    # Convert model
    if convert_pyannote_via_onnx(hf_token):
        print("\n✅ Success! Pyannote model ready for use in AlmRecorder")
    else:
        print("\n❌ Conversion failed")
        sys.exit(1)

if __name__ == "__main__":
    main()