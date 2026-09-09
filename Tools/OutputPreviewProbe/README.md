# Metal output preview

Tap **Monitor** to switch between INPUT and OUTPUT. OUTPUT uses the Metal
renderer; there is no renderer setting or comparison menu.

The Metal preview reads the finished, pre-encoder-compression HLG/BT.2020 frame.
It maps the existing Y and CbCr planes as read-only GPU textures and writes a
separate half-float RGB drawable. It does not modify the camera buffer, overlay
compositing, color attachments, encoder configuration, recording or stream.
At most two preview frames can be in flight; busy previews drop frames.

The shader reconstructs HLG RGB from full- or video-range ten-bit YCbCr,
accounting for declared chroma siting. It uses the compositor's fixed BT.2100
HLG reference EOTF (1,000-nit peak, system gamma 1.2), scaling 203-nit graphics
white to EDR 1.0. The display layer uses linear BT.2020 and `toneMapMode = .never`
so AVFoundation's HLG presentation adjustment is not applied again.

Colors whose maximum linear component is at or below 1.0 keep the same values
at every display headroom. For brighter colors, the shader scales all three
components together to fit the current screen headroom. Its highlight curve
joins SDR white with slope one and maps the reference peak to the available
peak. With no HDR headroom it limits the maximum component to one. This is a
preview rendering choice, not a change to the HLG signal sent to YouTube.

## Validation without a phone

On a Mac with Xcode and GPU access:

```sh
bash Tools/OutputPreviewProbe/validate.sh
```

The probe compiles the production Swift pipeline and Metal shaders. An
independent Double-precision reference reconstructs quantized input samples,
including bilinear chroma interpolation, and evaluates the HLG EOTF. It checks
150 GPU frames across 4:2:0/4:2:2 full and video range, 4:4:4 video range, six
chroma locations, and headroom 1, 1.25, 2, 1000/203 and 8. Asymmetric patches
check orientation; colors, gray ramps and HDR highlights check rendering.

Every comparison checks source plane bytes (including padding) and attachments
for exact preservation. SDR output must be bit-identical across headrooms;
HDR peak white must reach the available headroom. Missing HLG metadata and
unsupported pixel formats must be rejected. The tolerance against the CPU
reference is 0.006 in linear EDR units, allowing half-float output quantization.

`testOutputPreviewCanBeOpenedAndRestored` checks opening and closing OUTPUT,
background/foreground restoration and reopening OUTPUT after an app restart
in the simulator, including the unavailable-Metal explanation on virtual hosts
without a GPU. These checks cannot validate physical iPhone luminance or
the platform's EDR display behavior. Compare INPUT and OUTPUT on the phone
with the same source and brightness when changing the presentation arithmetic.
