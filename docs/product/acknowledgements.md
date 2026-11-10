# Acknowledgements and third-party software

Pichi Voice is a modified downstream of [FluidVoice](https://github.com/altic-dev/FluidVoice). Pichi development began from upstream commit `7daffb529fb9f7c8d075f686a2d3da34695a66e4` on October 6, 2026 and continues to integrate upstream work. Pichi changes include product identity, local meeting workflows, mobile recording, Russian-language capabilities and additional speech backends.

The application remains under [GNU GPL version 3](../../LICENSE). Original copyright, license notices and upstream Git history are preserved. Pichi Voice is a separate distribution; upstream developers do not provide support for Pichi-specific releases.

## Bundled notices and components

The [notice resources](../../Sources/Fluid/Resources/Notices) include upstream notices and licenses. The [mobile notice index](../../Sources/Fluid/Resources/Notices/MobileLicenses.json) records the resources shown by the mobile legal interface.

Native components have their own provenance and build documentation:

- [Pichi GigaAM](../../Vendor/PichiGigaAM/README.md)
- [Native text inference](../../Vendor/NativeTextInference/README.md)
- [WebRTC audio processing](../../Vendor/WebRTCAudioProcessing/README.md)
- [Call observation module](../../Vendor/PichiCallObservation/README.md)

Model weights are obtained separately. Their publisher names, licenses and source attribution remain attached to each selected model. The application's GPL license does not replace a model's license. Check the selected artifact's license before redistribution.

## Corresponding source

Use the exact source revision and source archive identified in each binary release's notes. The development branch may have changed since that binary was built. Source packages include applicable license files, dependency lockfiles and build instructions; they exclude personal data, signing keys and model weights.

Inherited technical names remain where they form build, storage, localization or compatibility contracts. They are not a claim that the Pichi distribution is the upstream product.
