# Russian local model options

Reviewed October 9-10, 2026. Model cards and artifact sizes below are publisher evidence, not measurements on an 8 GB Mac. A weight file's size does not include the KV cache, runtime, audio buffers or macOS.

## Speech recognition

Keep the existing optimized GigaAM v3 end-to-end CTC export as the initial Russian provider. The upstream GigaAM evaluation reports 6.1% WER on Golos Farfield, 9.6% on Natural Speech and 12.0% averaged over its ten sets for E2E CTC. E2E RNNT scores 5.5%, 8.5% and 11.2%. Those are different variants; the 9.1% average for plain v3 CTC is not the score of our end-to-end artifact. [Publisher evaluation](https://github.com/salute-developers/GigaAM/blob/main/evaluation.md)

T-bank's T-one is a useful streaming candidate: 71M parameters, 300 ms input chunks and an Apache-2.0 license. Its telephone benchmarks compare against older GigaAM v2, so they do not establish a general win against v3. [T-one model card](https://huggingface.co/t-tech/T-one)

Its ONNX acoustic model is 144 MB, but the published KenLM file is 5.46 GB. Evaluate greedy decoding or a bounded decoder separately before calling the complete pipeline small. [Publisher artifacts](https://huggingface.co/t-tech/T-one/tree/main)

New GigaAM Multilingual 220M/600M checkpoints are candidates when other languages are needed. Their Russian FLEURS scores are 4.4%/3.0%, under a separate normalization and sample-filtering protocol. These figures cannot be directly ranked against the ten-set Russian ASR average above. [Multilingual evaluation](https://github.com/salute-developers/GigaAM/blob/main/evaluation.md)

No official downloadable Yandex local ASR checkpoint was verified in this investigation. SpeechKit availability alone is not evidence of an open model suitable for bundling.

## Text generation and summaries

| Candidate | Published local artifact | Practical evaluation priority |
| --- | --- | --- |
| T-lite-it-2.1, 8B | Q4_K_M, 5.03 GB | First Russian-specific candidate for 16 GB or larger Macs |
| YandexGPT 5 Lite Instruct, 8B | Q4_K_M, 4.92 GB | Compare with the correct publisher chat template and license |
| GigaChat 3.1 Lightning, 10B total / 1.8B active | Q4_K_M, 6.47 GB | Larger memory budget; active parameters do not measure stored weights |

Artifact sources: [T-lite](https://huggingface.co/t-tech/T-lite-it-2.1-GGUF/tree/main), [YandexGPT](https://huggingface.co/yandex/YandexGPT-5-Lite-8B-instruct-GGUF/tree/main), [GigaChat](https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF/tree/main).

T-lite's publisher reports ruIFeval 75.9 and Ru Arena Hard 83.9 for the original BF16 model, compared with 74.0 and 57.2 for Qwen3-8B without thinking under its evaluation. The separate GGUF evaluation reports Ru Arena Hard 71.7 and ruIFeval 75.9 for Q4_K_M. Do not attribute the BF16 83.9 score to the 5.03 GB quantized artifact above. These scores support evaluating T-lite but do not measure faithful meeting summaries or compare directly with our smaller Qwen model. [Original model card and benchmark protocol](https://huggingface.co/t-tech/T-lite-it-2.1), [publisher quantization benchmarks](https://huggingface.co/t-tech/T-lite-it-2.1-GGUF#-benchmarks).

YandexGPT uses its own conversation template and a custom license. Review its terms for the intended distribution before selecting it. [Model card](https://huggingface.co/yandex/YandexGPT-5-Lite-8B-instruct), [license](https://huggingface.co/yandex/YandexGPT-5-Lite-8B-instruct/blob/main/LICENSE).

The newer AliceAI-T5-35B-A0.6B has 35B total parameters. Its small active-parameter count does not make the weight set an 8 GB desktop choice. [Publisher model card](https://huggingface.co/yandex/AliceAI-T5-35B-A0.6B)

The current local default remains `qwen3.5:4b` through the existing configurable text-provider endpoint. The bounded 8192-token Ollama configuration used about 3.15 GiB of model memory in our local run, with ASR retired before generation and the LLM unloaded afterward. Physical 8 GB and Intel measurements remain necessary.

## Selection gate

Use the same approved recordings and human-checked transcripts for ASR comparisons. Report WER, names, domain vocabulary, first-caption latency, final latency and peak resident memory. A saved Parakeet transcript is another hypothesis, not a gold reference.

For summaries, compare all models on the same synthetic Russian meetings: quoted source evidence, JSON/schema validity, task owners and dates, canceled and reinstated decisions, and questions answered later. There is no verified common publisher benchmark for this exact application task. Keep provider configuration independent of the meeting pipeline and brand package.
