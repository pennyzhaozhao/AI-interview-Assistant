// Bridging header for the app target: exposes ONNX Runtime's C API (MIT, vendored from Microsoft.ML.OnnxRuntime 1.28.0)
// to LocalEmbeddingService.swift. The runtime library itself is the one already shipped with sherpa-onnx
// (onnxruntime.framework); its symbols are looked up at run time, so nothing extra is linked here.
#include "ORT/onnxruntime_c_api.h"
