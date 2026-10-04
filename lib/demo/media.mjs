import { execFileSync } from 'node:child_process';
const ffmpegPath = process.env.FFMPEG ?? 'ffmpeg';

const ffmpeg = (args) => execFileSync(ffmpegPath, ['-y', '-loglevel', 'error', ...args]);

/** Joins WebM clips into one H.264 MP4 that browsers and GitHub play inline. */
export function concatVideos(inputs, output) {
  const filter = inputs.map((_, i) => `[${i}:v]`).join('') + `concat=n=${inputs.length}:v=1:a=0[v]`;
  ffmpeg([
    ...inputs.flatMap((f) => ['-i', f]),
    '-filter_complex', filter, '-map', '[v]',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '26', '-movflags', '+faststart', output,
  ]);
}

/** Small looping GIF for inline display in PR comments. */
export function toGif(input, output, { width = 720, fps = 5 } = {}) {
  ffmpeg([
    '-i', input,
    '-vf', `fps=${fps},scale=${width}:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer`,
    '-loop', '0', output,
  ]);
}

/** Turns still frames into a slideshow video, each frame shown for `seconds`. */
export function slideshow(frames, output, { seconds = 3 } = {}) {
  const filter = frames.map((_, i) => `[${i}:v]scale=1600:-2,setsar=1[f${i}]`).join(';') + ';'
    + frames.map((_, i) => `[f${i}]`).join('') + `concat=n=${frames.length}:v=1:a=0,format=yuv420p[v]`;
  ffmpeg([
    ...frames.flatMap((f) => ['-loop', '1', '-t', String(seconds), '-framerate', '10', '-i', f]),
    '-filter_complex', filter, '-map', '[v]',
    '-c:v', 'libx264', '-crf', '26', '-movflags', '+faststart', output,
  ]);
}
