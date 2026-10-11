import { atom, memberOf, read, update } from 'claude-code'
import type { Elements, EngineInterface, PromptEditResult, Register } from 'claude-code'

import type { Picture } from '../types'

type Block = { type: string; [field: string]: unknown }
type ImageSource = { type?: string; media_type?: string; data?: string }
type Size = { width: number; height: number }
type Ran = { exitCode: number | null; stdout: string }

// The hooks environment has the TC39 base64 helpers; TypeScript's es2023 lib does not declare them yet.
const fromBase64 = (base64: string) =>
  (Uint8Array as unknown as { fromBase64: (text: string) => Uint8Array }).fromBase64(base64)
const toBase64 = (bytes: Uint8Array) => (bytes as unknown as { toBase64: () => string }).toBase64()

const MAX_COLUMNS = 40
const MAX_ROWS = 12
const UPPER_HALF = 0x2580
const LOWER_HALF = 0x2584
const SPACE = 0x20
const DEFAULT_COLOR = 0x01000000

const PASTE_ONLY = /^\[Pasted text #\d+[^\]]*\]$/
const HAS_PASTE = /\[Pasted text #\d+[^\]]*\]/
const PASTES = /\[Pasted text #\d+[^\]]*\]/g
const IMAGES = /\[Image #(\d+)\]/g

const CLIPBOARD_TO_PNG = [
  'on run argv',
  'set outFile to open for access (POSIX file (item 1 of argv)) with write permission',
  'try',
  'set eof outFile to 0',
  'write (the clipboard as «class PNGf») to outFile',
  'close access outFile',
  'on error errorText',
  'close access outFile',
  'error errorText',
  'end try',
  'end run',
].flatMap(line => ['-e', line])

const SAVE_AS_PNG = '[Drawing.Imaging.ImageFormat]::Png'

const draft = atom({ plugin: 'paste-preview', key: 'draft' } as const, [])
const sent = atom({ plugin: 'paste-preview', key: 'sent' } as const, [])
const fullText = atom({ plugin: 'paste-preview', key: 'fullText' } as const, '')

const triedLabels = new Set<string>()
let isWindowsHost: Promise<boolean> | undefined
let workDirectory: Promise<string> | undefined
let isSyncing = false

const succeeded = async (run: Promise<Ran>) => (await run).exitCode === 0

const sizeOf = (width?: string, height?: string): Size | null => {
  const size = { width: Number(width ?? 0), height: Number(height ?? 0) }

  return size.width > 0 && size.height > 0 ? size : null
}

const quoted = (text: string) => `'${text.replace(/'/g, "''")}'`

const powershell = ($: EngineInterface, lines: string[], stdin?: string) =>
  $.process.run(
    [
      'powershell.exe',
      '-NoProfile',
      '-NonInteractive',
      '-STA',
      '-Command',
      ["$ErrorActionPreference = 'Stop'", 'Add-Type -AssemblyName System.Drawing, System.Windows.Forms', ...lines].join('; '),
    ],
    stdin === undefined ? {} : { stdin },
  )

const isWindows = ($: EngineInterface) => (isWindowsHost ??= $.env.get('OS').then(os => os === 'Windows_NT'))

const makeDirectory = async ($: EngineInterface, path: string) =>
  (await isWindows($))
    ? succeeded(powershell($, [`New-Item -ItemType Directory -Force -Path ${quoted(path)} | Out-Null`]))
    : succeeded($.process.run(['/bin/mkdir', '-p', path]))

// On Windows the text crosses PowerShell's stdout as base64 of its UTF-8 bytes: the console code page would mangle accents.
const clipboardText = async ($: EngineInterface) => {
  if (await isWindows($)) {
    const { exitCode, stdout } = await powershell($, [
      '$text = [Windows.Forms.Clipboard]::GetText()',
      '[Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)))',
    ])

    return exitCode === 0 ? new TextDecoder().decode(fromBase64(stdout.trim())) : ''
  }

  const { exitCode, stdout } = await $.process.run(['/usr/bin/pbpaste'])

  return exitCode === 0 ? stdout : ''
}

const clipboardPng = async ($: EngineInterface, png: string) =>
  (await isWindows($))
    ? succeeded(
        powershell($, [
          '$image = [Windows.Forms.Clipboard]::GetImage()',
          'if ($null -eq $image) { exit 1 }',
          `$image.Save(${quoted(png)}, ${SAVE_AS_PNG})`,
        ]),
      )
    : succeeded($.process.run(['/usr/bin/osascript', ...CLIPBOARD_TO_PNG, png]))

const savePng = async ($: EngineInterface, png: string, base64: string, mediaType: string) => {
  if (await isWindows($)) {
    return succeeded(
      powershell(
        $,
        [
          '$bytes = [Convert]::FromBase64String([Console]::In.ReadToEnd())',
          `[Drawing.Image]::FromStream([IO.MemoryStream]::new($bytes)).Save(${quoted(png)}, ${SAVE_AS_PNG})`,
        ],
        base64,
      ),
    )
  }

  const raw = png.replace(/\.png$/, `.${mediaType.split('/')[1] ?? 'png'}`)
  const isDecoded = await succeeded($.process.run(['/usr/bin/base64', '-d', '-o', raw], { stdin: base64 }))

  return isDecoded && (raw === png || (await succeeded($.process.run(['/usr/bin/sips', '-s', 'format', 'png', raw, '--out', png]))))
}

const imageSize = async ($: EngineInterface, image: string) => {
  if (await isWindows($)) {
    const { exitCode, stdout } = await powershell($, [
      `$image = [Drawing.Image]::FromFile(${quoted(image)})`,
      '[Console]::Out.Write("$($image.Width) $($image.Height)")',
    ])
    const match = /^(\d+) (\d+)/.exec(stdout.trim())

    return exitCode === 0 ? sizeOf(match?.[1], match?.[2]) : null
  }

  const { exitCode, stdout } = await $.process.run(['/usr/bin/sips', '-g', 'pixelWidth', '-g', 'pixelHeight', image])

  return exitCode === 0 ? sizeOf(/pixelWidth: (\d+)/.exec(stdout)?.[1], /pixelHeight: (\d+)/.exec(stdout)?.[1]) : null
}

const toBmp = async ($: EngineInterface, png: string, bmp: string, width: number, height: number) =>
  (await isWindows($))
    ? succeeded(
        powershell($, [
          `$image = [Drawing.Image]::FromFile(${quoted(png)})`,
          `$bitmap = [Drawing.Bitmap]::new(${width}, ${height}, [Drawing.Imaging.PixelFormat]::Format24bppRgb)`,
          '$graphics = [Drawing.Graphics]::FromImage($bitmap)',
          '$graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic',
          `$graphics.DrawImage($image, 0, 0, ${width}, ${height})`,
          `$bitmap.Save(${quoted(bmp)}, [Drawing.Imaging.ImageFormat]::Bmp)`,
        ]),
      )
    : succeeded(
        $.process.run(['/usr/bin/sips', '-s', 'format', 'bmp', '-z', String(height), String(width), png, '--out', bmp]),
      )

const directory = ($: EngineInterface) =>
  (workDirectory ??= (async () => {
    const tmp = ((await isWindows($)) ? await $.env.get('TEMP') : await $.env.get('TMPDIR')) ?? '/tmp'
    const path = `${tmp.replace(/[\\/]+$/, '')}/claude-paste-preview`
    await makeDirectory($, path)

    return path
  })())

const hasKittyGraphics = async ($: EngineInterface) => {
  const program = (await $.env.get('TERM_PROGRAM')) ?? ''

  return ['ghostty', 'kitty', 'WezTerm'].includes(program) || (await $.env.get('KITTY_WINDOW_ID')) !== undefined
}

const isPerson = (kind: string) => kind === 'composer' || kind === 'bridge'

const lowestBit = (mask: number) => (mask === 0 ? 0 : 31 - Math.clz32(mask & -mask))

// sips writes 32-bit BMPs with channel masks (BGRA, top-down); System.Drawing writes 24-bit BGR, bottom-up.
const decodeBmp = (bytes: Uint8Array) => {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

  if (bytes.byteLength < 54 || view.getUint16(0, true) !== 0x4d42) {
    return null
  }

  const offset = view.getUint32(10, true)
  const width = view.getInt32(18, true)
  const rawHeight = view.getInt32(22, true)
  const bitsPerPixel = view.getUint16(28, true)
  const hasMasks = view.getUint32(30, true) === 3 && bytes.byteLength >= 70
  const height = Math.abs(rawHeight)
  const stride = Math.ceil((width * bitsPerPixel) / 32) * 4
  const masks = hasMasks
    ? [view.getUint32(54, true), view.getUint32(58, true), view.getUint32(62, true), view.getUint32(66, true)]
    : [0xff0000, 0xff00, 0xff, bitsPerPixel === 32 ? 0xff000000 : 0]

  if (bitsPerPixel !== 24 && bitsPerPixel !== 32) {
    return null
  }

  return (x: number, y: number) => {
    const line = rawHeight > 0 ? height - 1 - y : y
    const at = offset + line * stride + (x * bitsPerPixel) / 8

    if (at + bitsPerPixel / 8 > bytes.byteLength) {
      return DEFAULT_COLOR
    }

    const pixel =
      bitsPerPixel === 32
        ? view.getUint32(at, true)
        : ((bytes[at + 2] ?? 0) << 16) | ((bytes[at + 1] ?? 0) << 8) | (bytes[at] ?? 0)
    const [red, green, blue, alpha] = masks.map(mask => ((pixel & mask) >>> lowestBit(mask)) & 0xff) as [
      number,
      number,
      number,
      number,
    ]
    const isTransparent = masks[3] !== 0 && alpha < 128

    return isTransparent ? DEFAULT_COLOR : (red << 16) | (green << 8) | blue
  }
}

const rasterCells = async ($: EngineInterface, png: string, columns: number, rows: number) => {
  const bmp = png.replace(/\.png$/, `-${columns}x${rows}.bmp`)

  if (!(await toBmp($, png, bmp, columns, rows * 2))) {
    return null
  }

  const { base64 } = await $.fs.read(bmp, { as: 'bytes' })
  const pixelAt = decodeBmp(fromBase64(base64))

  if (pixelAt === null) {
    return null
  }

  const words = new Uint32Array(columns * rows * 3)

  for (let row = 0; row < rows; row++) {
    for (let column = 0; column < columns; column++) {
      const top = pixelAt(column, row * 2)
      const bottom = pixelAt(column, row * 2 + 1)
      const at = (row * columns + column) * 3

      if (top === DEFAULT_COLOR && bottom === DEFAULT_COLOR) {
        words.set([SPACE, DEFAULT_COLOR, DEFAULT_COLOR], at)
      } else if (top === DEFAULT_COLOR) {
        words.set([LOWER_HALF, bottom, DEFAULT_COLOR], at)
      } else {
        words.set([UPPER_HALF, top, bottom], at)
      }
    }
  }

  return toBase64(new Uint8Array(words.buffer))
}

const picture = async ($: EngineInterface, png: string, label: string): Promise<Picture | null> => {
  const size = await imageSize($, png)

  if (size === null) {
    return null
  }

  let columns = Math.min(MAX_COLUMNS, size.width)
  let rows = Math.max(1, Math.round((columns * size.height) / size.width / 2))

  if (rows > MAX_ROWS) {
    rows = MAX_ROWS
    columns = Math.max(1, Math.min(MAX_COLUMNS, Math.round((rows * 2 * size.width) / size.height)))
  }

  return { label, path: png, columns, rows, cells: await rasterCells($, png, columns, rows) }
}

const syncDraft = async ($: EngineInterface, text: string) => {
  if (isSyncing) {
    return
  }

  isSyncing = true

  try {
    const wanted = [...text.matchAll(IMAGES)].map(match => `Image #${match[1]}`)
    const current = await read($, draft)
    const missing = wanted.filter(label => !triedLabels.has(label) && !current.some(one => one.label === label))
    const isStale = current.some(one => !wanted.includes(one.label))

    if (missing.length === 0 && !isStale) {
      return
    }

    missing.forEach(label => triedLabels.add(label))
    const newest = missing.at(-1)
    let added: Picture | null = null

    if (newest !== undefined) {
      const png = `${await directory($)}/draft-${crypto.randomUUID()}.png`
      added = (await clipboardPng($, png)) ? await picture($, png, newest) : null
    }

    await update($, draft, list => [
      ...list.filter(one => wanted.includes(one.label)),
      ...(added === null ? [] : [added]),
    ])
  } finally {
    isSyncing = false
  }
}

// The preview made while typing is reused, so the message row has its pictures from its first draw.
const sentPictures = async ($: EngineInterface, uuid: string, text: string, images: Block[], drafts: Picture[]) => {
  const numbers = [...text.matchAll(IMAGES)].map(match => match[1])
  const pictures: Picture[] = []

  for (const [index, block] of images.entries()) {
    const label = `Image #${numbers[index] ?? index + 1}`
    const drafted = drafts.find(one => one.label === label)
    const source = block.source as ImageSource | undefined

    if (drafted !== undefined) {
      pictures.push(drafted)
    } else if (source?.type === 'base64' && typeof source.data === 'string') {
      const png = `${await directory($)}/${uuid}-${index}.png`
      const isSaved = await savePng($, png, source.data, source.media_type ?? 'image/png')
      const one = isSaved ? await picture($, png, label) : null

      if (one !== null) {
        pictures.push(one)
      }
    }
  }

  return pictures
}

const expandCollapsed = (before: string, box: PromptEditResult, pasted: string): PromptEditResult => {
  if (HAS_PASTE.test(pasted)) {
    return box
  }

  const previous = new Set(before.match(PASTES) ?? [])
  const fresh = (box.text.match(PASTES) ?? []).find(one => !previous.has(one))

  if (fresh === undefined) {
    return box
  }

  const at = box.text.indexOf(fresh)

  return {
    text: box.text.slice(0, at) + pasted + box.text.slice(at + fresh.length),
    cursor: at + pasted.length,
  }
}

const pictureRow = (ui: Elements['terminal'], pictures: Picture[], isKitty: boolean) => {
  const { Box, Text, Image, Raster } = ui

  return (
    <Box flexDirection="row" gap={2}>
      {pictures.map(one => (
        <Box key={one.path} flexDirection="column">
          <Text dimColor>{one.label}</Text>
          {isKitty || one.cells === null ? (
            <Image source={{ file: one.path, format: 'png' }} columns={one.columns} rows={one.rows} alt={one.label} />
          ) : (
            <Raster key={one.path} columns={one.columns} rows={one.rows} cells={one.cells} />
          )}
        </Box>
      ))}
    </Box>
  )
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    $.clock.every(1000, () => {
      void $.prompt.read().then(box => syncDraft($, box.text))
    })

    return next(e)
  })

  on('prompt.edit', async ($, e, next) => {
    const isPaste = e.key === undefined && e.inputText !== ''
    const clip = isPaste && PASTE_ONLY.test(e.inputText.trim()) ? await clipboardText($) : ''
    const pasted = clip.trim() === '' ? e.inputText : clip.replace(/\r\n?/g, '\n')
    const box = await next(pasted === e.inputText ? e : { ...e, inputText: pasted })
    const result = isPaste ? expandCollapsed(e.text, box, pasted) : box
    await syncDraft($, result.text)

    return result
  }).catch(($, e, next) => next(e))

  on('session.append', { door: 'prompt' }, async ($, e, next) => {
    const stored = await next(e)

    if (!isPerson(e.origin.kind) || e.agentId !== undefined || stored.uuid === undefined) {
      return stored
    }

    const uuid = stored.uuid
    const blocks: Block[] = stored.message.content
    const first = blocks.find(block => block.type === 'text')
    const text = typeof first?.text === 'string' ? first.text : ''
    const images = blocks.filter(block => block.type === 'image')
    const drafts = await read($, draft)

    await update($, memberOf(fullText, { requestId: uuid }), () => text)
    await update($, draft, () => [])
    triedLabels.clear()

    if (images.length > 0) {
      const pictures = await sentPictures($, uuid, text, images, drafts)

      if (pictures.length > 0) {
        await update($, memberOf(sent, { requestId: uuid }), () => pictures)
      }
    }

    return stored
  }).catch(($, e, next) => next(e))

  on('session.append', { door: 'attachment' }, async ($, e, next) => {
    const stored = await next(e)

    if (stored.uuid === undefined || stored.message.name !== 'queued_command' || e.agentId !== undefined) {
      return stored
    }

    const uuid = stored.uuid
    const blocks: Block[] = e.message.content
    const images = blocks.filter(block => block.type === 'image')

    if (images.length > 0) {
      const text = blocks.flatMap(block => (typeof block.text === 'string' ? [block.text] : [])).join('\n')
      const pictures = await sentPictures($, uuid, text, images, await read($, draft))

      if (pictures.length > 0) {
        await update($, memberOf(sent, { requestId: uuid }), () => pictures)
      }
    }

    return stored
  }).catch(($, e, next) => next(e))

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)

    if (e.surface !== 'terminal' || e.props.hasSurvey) {
      return beneath
    }

    const pictures = await read($, draft)

    if (pictures.length === 0) {
      return beneath
    }

    const ui = $.ui.resolve(e)
    const { Box } = ui

    return (
      <Box flexDirection="column">
        {beneath}
        {pictureRow(ui, pictures, await hasKittyGraphics($))}
      </Box>
    )
  })

  on('ui.render', { component: 'UserMessage' }, async ($, e, next) => {
    if (!isPerson(e.props.origin.kind)) {
      return next(e)
    }

    const full = HAS_PASTE.test(e.props.text) ? await read($, memberOf(fullText, e)) : ''
    const pictures = await read($, memberOf(sent, e))
    const row = await next(full === '' ? e : { ...e, props: { ...e.props, text: full } })

    if (e.surface !== 'terminal' || pictures.length === 0) {
      return row
    }

    const ui = $.ui.resolve(e)
    const { Box } = ui

    return (
      <Box flexDirection="column">
        {row}
        {pictureRow(ui, pictures, await hasKittyGraphics($))}
      </Box>
    )
  })
}
