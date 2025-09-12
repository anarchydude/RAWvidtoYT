# RAWvidtoYT
Codebase to take raw video (DVD, DV Tape, MKVs..) and deinterlace/double framerate with QTGMC, then upscale to 4k for YouTube uploading.

I've got a lot of old VHS tapes and DVDs and MiniDV tapes that I am preserving. I've used apps on Windows that harness the famous QTGMC deinterlacer, but I can not find anything on macOS to leverage. Now, to be fair, this codebase was created with the assistance of AI so that I could get up to speed fast while I learned the intricacies of Vapoursynth.

I'd love to see this also port over to Linux and Windows, since those have more native tools to compile with. But for now, this is what fits my needs. Any PRs are welcome.

## How to use

Follow the installation steps in vapoursyth_qtgmc.md to get all the pre-reqs set. This assumes you have brew on your mac. You'll need MakeMKV for ripping DVDs. This installs vapoursynth, ffmpeg, and the tools to compile qtgmc and other compression tools.

The main script uses qtgmc_batch.sh to take a file, folder, or a disc and then leverage vapoursynth's vspipe command structure to deinterlace it, then run it through ffmpeg to get it encoded to YouTube's standard for VP9 encoding, which typically crunches your video quality less.

## Caveats

This is rather CPU intensive, since by default, vspipe will consume all your CPUs. Now, thankfully at least we can leverage videotoolbox to reduce some of the burden when using ffmpeg. There is a variable set to specify how many cores you want to use. I have an M3 Pro Max, so I've allocated 8 of the 14 cores.

I am working on reducing more overhead by not extracting a YUV422 high caliber file for ffmpeg to crunch, as that is a huge pipeline of data. YUV408 is acceptable for YT since that is what it will get crunched to, anyways.
