# Cloud provider icons

Retrieved on October 12, 2026 from the providers' official websites. These are third-party service identity marks, independent of the imported application brand. They identify the configured service and do not imply endorsement or partnership. No runtime downloads are performed.

| Service | Official source page | Page-linked original asset | SHA-256 of retained SVG |
| --- | --- | --- | --- |
| GigaChat | [Official help](https://giga.chat/help/articles/how-to-start-work-with-gigachat) | [favicon.svg](https://giga.chat/help/favicon/favicon.svg) | `229b84080dbe877d5ba06aea091b353c23e01b81bcb1bc9e73c27bb3cff1fe7e` |
| Yandex AI Studio | [Official website](https://aistudio.yandex.ru/) | [favicon.svg](https://aistudio.yandex.ru/favicon/svg/favicon.svg) | `78366d9a8738e670d219f36ae0b53df2c88ea2117e16c7c8bf10946bfb03ec15` |

The original SVGs are retained byte-for-byte here. They are provider trademarks, not project-created or GPL-licensed artwork. No independent redistribution license is asserted. Follow the providers' applicable trademark rules when distributing these identifying assets.

The GigaChat mark is the black symbol published by its official help site. Yandex AI Studio publishes a full-color circular icon. The original paths, proportions, colors, viewports and alpha are preserved. GigaChat is rendered directly from its transparent SVG, avoiding the white rectangle in the site's Apple-touch PNG.

The local GigaAM speech provider also uses the existing GigaChat mark through its shared provider presentation metadata. The [official GigaAM announcement](https://sberdevices.ru/press/detail/sber-devices-predstavila-giga-am-semejstvo-open-source-modelej-mashinnogo-obucheniya-dlya-raspoznavaniya-rechi-i-emoczij/) credits the GigaChat and SaluteSpeech teams at SberDevices. This is an author-team mark, not a separate GigaAM logo. The model's SaluteDevices publisher credit and local execution remain unchanged. Its neutral tile keeps the black mark visible in both app themes.

Raster renditions follow the existing `Provider_*` image set convention: 64 px at 1x and 128 px at 2x. The common provider tile remains 38 points, with a centered 26-point aspect-fit image and its existing neutral backing. That backing keeps the black mark legible in light and dark app themes without modifying or tinting the logo. Registration uses descriptor-owned `logoAssetName`; the UI uses the existing shared lookup and renderer.

Reproduce with librsvg 2.61.3:

```sh
rsvg-convert -w 64 -h 64 Configuration/ProviderLogoSources/gigachat-icon.svg -o Sources/Fluid/Assets.xcassets/Provider_GigaChat.imageset/logo.png
rsvg-convert -w 128 -h 128 Configuration/ProviderLogoSources/gigachat-icon.svg -o Sources/Fluid/Assets.xcassets/Provider_GigaChat.imageset/logo@2x.png
rsvg-convert -w 64 -h 64 Configuration/ProviderLogoSources/yandex-icon.svg -o Sources/Fluid/Assets.xcassets/Provider_Yandex.imageset/logo.png
rsvg-convert -w 128 -h 128 Configuration/ProviderLogoSources/yandex-icon.svg -o Sources/Fluid/Assets.xcassets/Provider_Yandex.imageset/logo@2x.png
```
