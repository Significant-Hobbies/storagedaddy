import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { pathToFileURL, fileURLToPath } from 'node:url';
import sharp from 'sharp';

const source = new URL('../public/storagedaddy/home/', import.meta.url);
const images = [
  { file: 'icon.png', name: 'icon', widths: [22, 44], width: 128, height: 128, sizes: '22px' },
  { file: 'storage-explorer.png', name: 'storage-explorer', widths: [480, 960, 1405], width: 1405, height: 768, sizes: '(min-width: 1024px) 896px, (min-width: 640px) calc(100vw - 128px), calc(100vw - 64px)' },
  { file: 'storagedaddy-scene-v1.webp', name: 'storagedaddy-scene', widths: [480, 960, 1536], width: 1536, height: 1024, sizes: '(min-width: 1200px) 1152px, calc(100vw - 32px)' },
  { file: 'storage-explorer.png', name: 'storage-detail', widths: [640, 1232], width: 1232, height: 340, crop: { left: 160, top: 210, width: 1232, height: 340 } },
  { file: 'ai-context.png', name: 'ai-context', widths: [350, 700], width: 700, height: 466 },
];
const srcset = (image) => image.widths.map((width) => `/home/${image.name}-${width}.webp ${width}w`).join(', ');
const src = (image) => `/home/${image.name}-${image.widths.at(-1)}.webp`;

// Preserve template markup and crop geometry; only change image delivery.
export async function optimizeLanding(dir) {
  const home = new URL('home/', dir);
  await mkdir(home, { recursive: true });
  for (const image of images) {
    for (const width of image.widths) {
      let pipeline = sharp(fileURLToPath(new URL(image.file, source)));
      if (image.crop) pipeline = pipeline.extract(image.crop);
      await pipeline.resize({ width }).webp({ quality: 85 }).toFile(fileURLToPath(new URL(`${image.name}-${width}.webp`, home)));
    }
  }
  const index = new URL('index.html', dir);
  let html = await readFile(index, 'utf8');
  html = html.replace(/<img\b[^>]*>/gi, (tag) => {
    const image = images.slice(0, 3).find((image) => tag.includes(`src="/home/${image.file}"`));
    if (!image) return tag;
    tag = tag.replace(`src="/home/${image.file}"`, `src="${src(image)}" srcset="${srcset(image)}" sizes="${image.sizes}"`);
    if (!/\bwidth=/.test(tag)) tag = tag.replace('<img ', `<img width="${image.width}" height="${image.height}" `);
    return tag;
  });
  // The template uses eager CSS backgrounds for below-fold detail images.
  // Export its exact crop and use native lazy loading without changing layout.
  html = html.replace(/<div role="img" aria-label="([^"]*)" class="w-full bg-no-repeat" style="aspect-ratio:[^;]*;background-image:url\(\/home\/(storage-explorer|ai-context)\.png\);[^"]*"><\/div>/g, (tag, alt, name) => {
    const image = images.find((image) => image.name === (name === 'storage-explorer' ? 'storage-detail' : name));
    return `<img src="${src(image)}" srcset="${srcset(image)}" sizes="(min-width: 1280px) 640px, (min-width: 768px) 55vw, calc(100vw - 48px)" alt="${alt}" width="${image.width}" height="${image.height}" loading="lazy" decoding="async" class="block w-full h-auto">`;
  });
  await writeFile(index, html);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await optimizeLanding(new URL('../public/storagedaddy/', import.meta.url));
}
