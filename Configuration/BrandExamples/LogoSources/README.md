# Official bank marks used by the appearance examples

Retrieved and visually checked on October 10, 2026 UTC. The examples remain demonstrations of the portable brand package, with invented voice-product names. They do not describe a bank product, affiliation or certification. The original marks and trademarks belong to their respective banks; their inclusion does not relicense that artwork under the application's GPL-3.0 license.

## Sources

| Mark | Official publication | Original file |
| --- | --- | --- |
| Sber | [Sber ID design guide](https://developers.sber.ru/docs/ru/sberid/service/design), updated December 26, 2025, links the logo download | [Sber_znachek_green.zip](https://cdn-app.sberdevices.ru/misc/0.0.0/assets/bsm-docs/3c763222_Sber_znachek_green.zip), member `Sber_znachek_green.svg`, preserved here as `sber-mark.svg` |
| Alfa-Bank | [Official Alfa Digital website](https://digital.alfabank.ru/) uses the mark in its footer with `alt="Альфа-Банк"` and a link to the bank | [a.svg](https://digital.alfabank.ru/images/a.svg), preserved here as `alfa-mark.svg` |

Sber's SVG is the green corporate circle/checkmark, without a Sber ID wordmark. Alfa-Bank's SVG is the red letter A and underline. Both files contain only SVG geometry and fixed fills, without scripts, remote references or fonts. The bank websites publish these variants; this check does not claim that a particular service's design guide is a complete corporate brandbook.

| Downloaded bytes | SHA-256 |
| --- | --- |
| Sber ZIP | `3c76322255694bb6b5f46322004b8072c69f93d17440890296cfc7635722fd33` |
| `sber-mark.svg` | `a97e54bc00d3587ec6ba7780662c564e5f4f40e5c53fc166fb2e65dd75f59eb0` |
| `alfa-mark.svg` | `33b7df33b909ae9c722178651897644c23ed9a71b1d8e144e0e1d76a4083defa` |

The main `alfabank.ru` pages returned HTTP 403 to this download session. The logo was obtained from the bank's public `digital.alfabank.ru` site instead of a third-party logo repository. Downloads used certificate verification. Where a Russian certificate chain required it, the task supplied a local CA bundle including [the published Russian Trusted Root CA](https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt), obtained with ordinary TLS verification. The [official government documentation](https://cdn.dom.gosuslugi.ru/webhelp/topics/login/administrative_body/t_add_main_certs-reg.html) links to [the certificate portal](https://www.gosuslugi.ru/crt). Its root fingerprint is `D26D2D0231B7C39F92CC738512BA54103519E4405D68B5BD703E9788CA8ECF31`. No system trust settings were changed, and certificate verification was never disabled.

## Raster conversion

The package decoder accepts PNG/JPEG, so `rsvg-convert 2.61.3` rasterized the original paths. Original aspect ratios, geometry and colors (`#21A038` and `#EF3124`) are unchanged. Transparent padding centers each mark; there is no white rectangle or AI-generated redraw. Identical full-color variants are embedded for the light and dark themes. The menu-bar PNG supplies the same shape as a template mask, colored by macOS at display time.

Run from the repository root, choosing an ignored output directory:

```bash
mkdir -p .build/bank-logo-output
rsvg-convert -w 384 -h 384 --keep-aspect-ratio --page-width 512 --page-height 512 --left 64 --top 64 Configuration/BrandExamples/LogoSources/sber-mark.svg -o .build/bank-logo-output/sber-primary.png
rsvg-convert -w 56 -h 56 --keep-aspect-ratio --page-width 64 --page-height 64 --left 4 --top 4 Configuration/BrandExamples/LogoSources/sber-mark.svg -o .build/bank-logo-output/sber-menu.png
rsvg-convert -h 384 --keep-aspect-ratio --page-width 512 --page-height 512 --left 117.333333 --top 64 Configuration/BrandExamples/LogoSources/alfa-mark.svg -o .build/bank-logo-output/alfa-primary.png
rsvg-convert -h 56 --keep-aspect-ratio --page-width 64 --page-height 64 --left 11.75 --top 4 Configuration/BrandExamples/LogoSources/alfa-mark.svg -o .build/bank-logo-output/alfa-menu.png
```

The complete files `sber-demo.json` and `alfa-demo.json` embed these raster bytes under `logos.primary`, `light`, `dark` and `menuBar`; the original SVGs are provenance only and are not required for importing a package. Each primary/theme image is 512 x 512 pixels and each menu-bar image is 64 x 64. Text/button accents are separate accessible UI colors, rather than edits to the official logo fills. Both examples pass the existing `BrandPackage`/ImageIO decoder and light/dark text-contrast validation through `bash Tests/run_brand_profile_tests.sh`.
