# LocalRAG

Local embedding model for knowledge-base retrieval (see `docs/LOCAL_RAG.md`).

`model/` is not stored in git (135 MB). Create it with:

```bash
scripts/fetch-rag-model.sh
```

It contains `model_quantized.onnx` and `tokenizer.json` from
[Xenova/multilingual-e5-small](https://huggingface.co/Xenova/multilingual-e5-small), an ONNX export of
[intfloat/multilingual-e5-small](https://huggingface.co/intfloat/multilingual-e5-small), published under the MIT
License according to its model card. The release builds bundle these files into the apps.
