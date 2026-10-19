# Segmentation fixture attribution

`Portrait-CC0.jpg` is Wikimedia Commons' **Portrait (CreativeCommons).jpg** by Wendelin Jacober, released under CC0 1.0. It is a public model portrait, not a PrivateCam camera capture. The fixture is used locally for prototype tests and benchmarks.

- Source and license record: https://commons.wikimedia.org/wiki/File:Portrait_(CreativeCommons).jpg
- License: https://creativecommons.org/publicdomain/zero/1.0/
- Original dimensions: 5472 × 3648
- Local fixture SHA-256: `d237bbf13f886b69a376aad00836403dafdb8a6be0062dc98a50e1a6c7b32a48`

`Portrait-Reference.jpg` was supplied inside the Aurevix Cam source update package as a software-test fixture. The package labels it as a demonstration portrait but does not state its source or license. It is used only for local offline refinement tests and is not included in the app bundle.

## Synthetic Skin Refinement portraits

The four `SkinTest-*.png` files were generated for this test set on 2026-10-19 using OpenAI image generation. They are synthetic adult portraits, created without a reference photo or real-person likeness target; no person's consent or private photo was used. The generation output is owned by the requesting user under the [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/). The images are used only for local offline software evaluation.

| Fixture | Prompt characteristics | SHA-256 |
|---|---|---|
| `SkinTest-medium-brown.png` | Adult woman, medium brown skin, natural hair, soft side-window light | `54dec50a7eb2d2e743af5a9d339b9477f0498773507a7bb98740d52d7d5a8574` |
| `SkinTest-light-textured.png` | Adult man, light freckled skin, warm indoor light, bright background | `b2a3eb08e591870b915184b03461bfb2affcd67d5db7c7abc807e1fd994f1105` |
| `SkinTest-deep-lowkey.png` | Adult woman, deep dark-brown skin, mixed light/dark background | `6ad2b0a66382c403044d83a6c28083500d0445a2eeb7e5179d033542db6750d0` |
| `SkinTest-light-medium.png` | Adult East Asian woman, light-medium skin, overcast light, pale background | `4b96e8cd802510a3c69af44da374217968e0b65a766fb31864b528eb7d23b593` |

These generated portraits have no third-party reuse restrictions known to this project. They are not legal releases or evidence of a real person's consent. `Portrait-Reference.jpg` has unknown provenance and is no longer used by Skin Refinement tests.
