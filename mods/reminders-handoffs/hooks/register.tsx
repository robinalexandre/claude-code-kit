import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Handoff, Reminder, Source } from '../types'

const PANE = 'reminders-handoffs'
const RELOAD_EVERY_MS = 60_000
const BODY_LINES = 12

const reminders = atom({ plugin: 'reminders-handoffs', key: 'reminders' } as const, null)
const handoffs = atom({ plugin: 'reminders-handoffs', key: 'handoffs' } as const, null)
const enabled = atom({ plugin: 'reminders-handoffs', key: 'enabled' } as const, [])
const problems = atom({ plugin: 'reminders-handoffs', key: 'problems' } as const, {})
const tab = atom({ plugin: 'reminders-handoffs', key: 'tab' } as const, 'reminders')
const openIds = atom({ plugin: 'reminders-handoffs', key: 'openIds' } as const, {})
const openSections = atom({ plugin: 'reminders-handoffs', key: 'openSections' } as const, {})
const armed = atom({ plugin: 'reminders-handoffs', key: 'armed' } as const, '')
const busy = atom({ plugin: 'reminders-handoffs', key: 'busy' } as const, '')

// Each part this pane shows: the skill that keeps it, its script, and the pane's words for it.
const SOURCES: Record<Source, { skill: string; script: string; title: string; command: string }> = {
  reminders: { skill: 'reminders', script: 'reminders.sh', title: 'Reminders', command: 'reminders' },
  handoffs: { skill: 'handoff', script: 'handoff.sh', title: 'Handoffs', command: 'handoffs' },
}

const slashed = (path: string) => path.replace(/\\/g, '/')

const truncate = (text: string, width: number) =>
  text.length > width ? `${text.slice(0, Math.max(0, width - 1))}…` : text

const tail = (path: string) => slashed(path).replace(/\/+$/, '').split('/').pop() ?? path

const home = async ($: EngineInterface) => slashed((await $.env.get('HOME')) ?? (await $.env.get('USERPROFILE')) ?? '~')

const runs = async ($: EngineInterface, argv: string[]) => {
  try {
    return (await $.process.run(argv, { timeoutMs: 10_000 })).exitCode === 0
  } catch {
    return false
  }
}

// On Windows, Claude Code's own PATH has Git's cmd folder (git) but not bash: Git Bash is found
// from the variable Claude Code reads for it, then from git's own install folder.
let bashFound: string | undefined

const bash = async ($: EngineInterface) => {
  if (bashFound !== undefined) {
    return bashFound
  }

  const fromGit = async () => {
    const execPath = await $.process.run(['git', '--exec-path'], { timeoutMs: 10_000 }).catch(() => undefined)
    const root = slashed(execPath?.stdout.trim() ?? '').replace(/\/(mingw64|clangarm64|mingw32)\/.*$/, '')

    return execPath?.exitCode === 0 && root !== '' ? `${root}/bin/bash.exe` : ''
  }
  const candidates = [
    async () => slashed((await $.env.get('CLAUDE_CODE_GIT_BASH_PATH')) ?? ''),
    async () => 'bash',
    fromGit,
    async () => `${slashed((await $.env.get('ProgramFiles')) ?? 'C:/Program Files')}/Git/bin/bash.exe`,
  ]

  for (const candidate of candidates) {
    const path = await candidate()

    if (path !== '' && (await runs($, [path, '-c', 'exit 0']))) {
      bashFound = path

      return path
    }
  }

  throw new Error('Git Bash not found: set CLAUDE_CODE_GIT_BASH_PATH to bash.exe')
}

// The skill copied into ~/.claude by install.sh, else installed as a plugin from the kit's
// marketplace; undefined when neither has the script (the part is not activated).
const scriptOf = async ($: EngineInterface, source: Source) => {
  const { skill, script } = SOURCES[source]
  const copied = `${await home($)}/.claude/skills/${skill}/${script}`

  if (await $.fs.exists(copied).catch(() => false)) {
    return copied
  }

  const config = slashed((await $.env.get('CLAUDE_CONFIG_DIR')) ?? `${await home($)}/.claude`)
  const installed = await $.fs
    .read(`${config}/plugins/installed_plugins.json`)
    .then(text => JSON.parse(String(text)) as { plugins?: Record<string, { installPath?: string }[]> })
    .catch(() => undefined)
  const root = installed?.plugins?.[`${skill}@claude-code-kit`]?.[0]?.installPath
  const fromPlugin = root ? `${slashed(root)}/skills/${skill}/${script}` : ''

  return fromPlugin !== '' && (await $.fs.exists(fromPlugin).catch(() => false)) ? fromPlugin : undefined
}

const scripts: Partial<Record<Source, string>> = {}

const detect = async ($: EngineInterface) => {
  const found: Source[] = []

  for (const source of Object.keys(SOURCES) as Source[]) {
    const path = await scriptOf($, source)

    if (path !== undefined) {
      scripts[source] = path
      found.push(source)
    }
  }

  await update($, enabled, () => found)

  if (!found.includes(await read($, tab)) && found[0] !== undefined) {
    await update($, tab, () => found[0] as Source)
  }

  return found
}

const run = async ($: EngineInterface, source: Source, args: string[]) =>
  $.process.run([await bash($), scripts[source] ?? '', ...args], { timeoutMs: 30_000 })

const loadOne = async ($: EngineInterface, source: Source) => {
  const setProblem = (text: string) => update($, problems, all => ({ ...all, [source]: text }))

  try {
    const args = source === 'reminders' ? ['json', slashed(await $.session.cwd())] : ['json']
    const ran = await run($, source, args)

    if (ran.exitCode !== 0) {
      await setProblem((ran.stderr.trim() || `${SOURCES[source].script} exited with ${ran.exitCode}`).split('\n')[0] ?? '')

      return
    }

    if (source === 'reminders') {
      await update($, reminders, () => JSON.parse(ran.stdout) as Reminder[])
    } else {
      await update($, handoffs, () => JSON.parse(ran.stdout) as Handoff[])
    }

    await setProblem('')
  } catch (error) {
    await setProblem(String(error).split('\n')[0] ?? '')
  }
}

const load = async ($: EngineInterface) => {
  for (const source of await read($, enabled)) {
    await loadOne($, source)
  }
}

let loadedAt = 0

const reload = async ($: EngineInterface) => {
  const now = await $.clock.now()

  if (now - loadedAt >= RELOAD_EVERY_MS) {
    loadedAt = now
    await load($)
  }
}

// The other computers get the change with the next sync; it runs in the background.
const shareChange = async ($: EngineInterface) => {
  const sync = `${await home($)}/.claude-sync/sync.sh`
  void $.process.run([await bash($), '-c', `[ -f "${sync}" ] && bash "${sync}" now`], { timeoutMs: 120_000 }).catch(() => undefined)
}

type Action = 'done' | 'stop' | 'delete' | 'cancel'

// done acts at once; the others ask for a second press.
const act = async ($: EngineInterface, source: Source, action: Action, id: string) => {
  const key = `${source}|${action}|${id}`

  if (action !== 'done' && (await read($, armed)) !== key) {
    await update($, armed, () => key)

    return
  }

  await update($, armed, () => '')
  await update($, busy, () => key)

  try {
    const ran = await run($, source, [action, id])

    if (ran.exitCode !== 0) {
      $.ui.toast(`Could not ${action} it: ${ran.stderr.trim().split('\n')[0] ?? ''}`)
    }

    await loadOne($, source)
    await shareChange($)
  } finally {
    await update($, busy, () => '')
  }
}

// The handoff skill picks the note up in this session, as if the user had asked.
const pick = async ($: EngineInterface, note: Handoff) => {
  await $.prompt.submit({ text: `Pick up the handoff ${note.id}: "${note.title}".` })
}

const openPane = async ($: EngineInterface, source?: Source) => {
  const found = await read($, enabled)
  const title = found.map(one => SOURCES[one].title).join(' & ') || 'Reminders'

  if (source !== undefined) {
    await update($, tab, () => source)
  }

  await $.ui.open({ id: PANE, title, columns: 64 })
  await load($)
}

const dayText = (stamp: string) => {
  const [day = '', time = ''] = stamp.split(' ')
  const [, month = '', date = ''] = day.split('-')

  return `${date}/${month}${time !== '' && time !== '00:00' ? ` ${time}` : ''}`
}

const isRepeating = (one: Reminder) => (one.every ?? '') !== ''

// What a reminder's line says about when: now, next time, since when it ended.
const whenText = (one: Reminder) => {
  if (one.state === 'past') {
    return one.closed ? `closed ${dayText(one.closed)}` : 'closed'
  }

  if (one.state === 'expired') {
    return one.until ? `ended ${dayText(one.until)}` : 'ended'
  }

  const repeat = isRepeating(one) ? `every ${one.every}` : ''

  if (one.state === 'due') {
    return repeat !== '' ? `now · ${repeat}` : 'now'
  }

  const next = one.next ?? one.on ?? ''
  const at = next !== '' ? dayText(next) : ''
  const where = [one.where ? `in ${tail(one.where)}` : '', one.machine ? `on ${one.machine}` : ''].filter(part => part !== '')
  const place = one.state === 'elsewhere' && where.length > 0 ? `only ${where.join(' ')}` : ''

  return [at, repeat, place].filter(part => part !== '').join(' · ')
}

const reminderSection = (one: Reminder) =>
  one.state === 'due' ? 'now' : one.state === 'past' || one.state === 'expired' ? 'past' : 'upcoming'

// A reminder is filed under its group (an organization, a client, a project), else the folder it
// is for, else the computer, else General; a handoff under its repo, else General.
const reminderGroup = (one: Reminder) =>
  one.group ?? (one.where ? tail(one.where) : one.machine ? `${one.machine} only` : 'General')

const handoffGroup = (note: Handoff) => (note.repo ? tail(note.repo) : 'General')

const byGroup = <T,>(rows: T[], groupOf: (row: T) => string) => {
  const groups = new Map<string, T[]>()

  for (const row of rows) {
    groups.set(groupOf(row), [...(groups.get(groupOf(row)) ?? []), row])
  }

  return [...groups.entries()].sort(([one], [other]) =>
    one === 'General' ? 1 : other === 'General' ? -1 : one.localeCompare(other)
  )
}

const counts = (shownReminders: Reminder[] | null, shownHandoffs: Handoff[] | null) => ({
  due: (shownReminders ?? []).filter(one => one.state === 'due').length,
  current: (shownReminders ?? []).filter(one => reminderSection(one) !== 'past').length,
  open: (shownHandoffs ?? []).filter(note => note.state === 'open').length,
  fromElsewhere: (shownHandoffs ?? []).filter(note => note.state === 'open' && note.isMine !== true).length,
})

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    for (const source of await detect($)) {
      await $.command.register({
        name: SOURCES[source].command,
        description:
          source === 'reminders'
            ? 'Show the reminders: due now, upcoming and repeating, past; close or stop one'
            : 'Show the handoff notes: open ones to pick up or cancel, done ones',
      })
    }

    void reload($)

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    void reload($)

    return next(e)
  })

  on('command.run', { command: 'reminders' }, async $ => {
    await openPane($, 'reminders')

    return { text: 'Reminders pane opened.' }
  })

  on('command.run', { command: 'handoffs' }, async $ => {
    await openPane($, 'handoffs')

    return { text: 'Handoffs pane opened.' }
  })

  // One button at the right of the band above the prompt, named after the parts activated, while
  // there is something in them: yellow when a reminder is due or a note from the other computer
  // waits.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const beneath = await next(e)
    const found = await read($, enabled)
    const { due, current, open, fromElsewhere } = counts(await read($, reminders), await read($, handoffs))

    if (e.props.hasSurvey || e.props.view.agentId !== undefined || current + open === 0) {
      return beneath
    }

    const { Box, Button, Text } = $.ui.resolve(e)
    const isUrgent = due + fromElsewhere > 0
    const parts = found.map(source =>
      source === 'reminders' ? `Reminders${due > 0 ? ` ${due} now` : ''}` : `Handoffs${open > 0 ? ` ${open}` : ''}`
    )
    const first = due > 0 || fromElsewhere === 0 ? found[0] : 'handoffs'

    return (
      <Box flexDirection="row" justifyContent="space-between" alignItems="flex-start">
        <Box flexDirection="column" flexShrink={1}>
          {beneath}
        </Box>
        <Box flexDirection="row" flexShrink={0}>
          {isUrgent && <Text color="yellow">● </Text>}
          <Button key="reminders-handoffs" label={parts.join(' · ')} dimColor={!isUrgent} onPress={() => void openPane($, first)} />
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Button, Text } = $.ui.resolve(e)
    const found = await read($, enabled)
    const current = await read($, tab)
    const shownReminders = await read($, reminders)
    const shownHandoffs = await read($, handoffs)
    const trouble = (await read($, problems))[current] ?? ''
    const unfolded = await read($, openIds)
    const sections = await read($, openSections)
    const armedKey = await read($, armed)
    const busyKey = await read($, busy)
    const width = Math.max(20, e.props.bodyColumns - 2)
    const { due, current: remindersCount, open } = counts(shownReminders, shownHandoffs)

    const actionButton = (source: Source, action: Action, id: string, label: string) => {
      const key = `${source}|${action}|${id}`

      if (busyKey === key) {
        return <Text key={`${action}-${id}`} dimColor>{`${action}… `}</Text>
      }

      return armedKey === key ? (
        <Button key={`${action}-${id}`} onPress={() => void act($, source, action, id)}>
          <Text color="red">{`${label}? press again`}</Text>
        </Button>
      ) : (
        <Button key={`${action}-${id}`} label={label} onPress={() => void act($, source, action, id)} />
      )
    }

    const textLines = (id: string, meta: string[], body: string) => {
      const lines = body
        .split(/\r?\n/)
        .map(line => line.replace(/[\x00-\x1f\x7f]/g, ' ').trimEnd())
        .filter((line, index, all) => line !== '' || (index > 0 && all[index - 1] !== ''))
      const shown = lines.length > BODY_LINES ? [...lines.slice(0, BODY_LINES), '…'] : lines

      return (
        <Box key={`details-${id}`} flexDirection="column" paddingLeft={4}>
          {meta.filter(line => line !== '').map((line, index) => (
            <Text key={`meta-${id}-${index}`} dimColor>
              {truncate(line, width - 4)}
            </Text>
          ))}
          {shown.map((line, index) => (
            <Text key={`body-${id}-${index}`}>{truncate(line, width - 4) || ' '}</Text>
          ))}
        </Box>
      )
    }

    // The buttons' labels set what is left for the title; when that leaves too little, the line drops
    // its "when", which the details still show.
    const row = (id: string, title: string, fullWhen: string, color: string, isStrong: boolean, isFaded: boolean, buttons: unknown[], labels: string[], details: () => unknown) => {
      const isOpen = unfolded[id] ?? false
      const room = width - 6 - labels.reduce((sum, label) => sum + label.length + 3, 0)
      const when = room - fullWhen.length - 3 >= Math.min(title.length, 12) ? fullWhen : ''
      const titleWidth = Math.max(8, room - (when === '' ? 0 : when.length + 3))

      return (
        <Box key={`row-${id}`} flexDirection="column" paddingLeft={2}>
          <Box flexDirection="row" justifyContent="space-between">
            <Box flexDirection="row" flexShrink={1}>
              <Button
                key={`toggle-${id}`}
                label={isOpen ? '▾' : '▸'}
                plain
                onPress={() => void update($, openIds, all => ({ ...all, [id]: !isOpen }))}
              />
              <Text>
                {' '}
                <Text color={color}>● </Text>
                <Text bold={isStrong} dimColor={isFaded}>
                  {truncate(title, titleWidth)}
                </Text>
                {when !== '' && <Text dimColor>{` · ${when}`}</Text>}
              </Text>
            </Box>
            <Box flexDirection="row" flexShrink={0} gap={1}>
              {buttons as never}
            </Box>
          </Box>
          {isOpen && (details() as never)}
        </Box>
      )
    }

    const reminderRow = (one: Reminder, color: string) => {
      const specs: [Action, string][] =
        one.state === 'past'
          ? [['delete', 'delete']]
          : one.state === 'due'
            ? isRepeating(one)
              ? [['done', 'done today'], ['stop', 'stop']]
              : [['done', 'done']]
            : [['stop', isRepeating(one) ? 'stop' : one.state === 'expired' ? 'close' : 'cancel']]
      const buttons = specs.map(([action, label]) => actionButton('reminders', action, one.id, label))
      const labels = specs.map(([, label]) => label)

      return row(one.id, one.title, whenText(one), color, one.state === 'due', one.state === 'past', buttons, labels, () =>
        textLines(
          one.id,
          [
            one.on ? `Starts: ${one.on}` : '',
            one.every ? `Repeats: every ${one.every}${one.next ? ` · next ${one.next}` : ''}${one.done ? ` · last done ${one.done}` : ''}` : '',
            one.until ? `Until: ${one.until}` : '',
            one.where ? `Folder: ${one.where}` : '',
            one.machine ? `Computer: ${one.machine}` : '',
            one.group ? `Group: ${one.group}` : '',
            one.closed ? `Closed: ${one.closed}` : '',
          ],
          one.body ?? ''
        )
      )
    }

    const handoffRow = (note: Handoff, color: string) => {
      const isOpenNote = note.state === 'open'
      const when = [note.from ? (note.isMine ? 'from this computer' : `from ${note.from}`) : '', note.date ? dayText(note.date) : '', note.state === 'canceled' ? 'canceled' : '']
        .filter(part => part !== '')
        .join(' · ')
      const pickKey = `handoffs|pick|${note.id}`
      const buttons = isOpenNote
        ? [
            busyKey === pickKey ? (
              <Text key={`pick-${note.id}`} dimColor>picking… </Text>
            ) : (
              <Button key={`pick-${note.id}`} label="pick" onPress={() => void pick($, note)} />
            ),
            actionButton('handoffs', 'cancel', note.id, 'cancel'),
          ]
        : [actionButton('handoffs', 'delete', note.id, 'delete')]

      const labels = isOpenNote ? ['pick', 'cancel'] : ['delete']

      return row(note.id, note.title, when, color, isOpenNote && note.isMine !== true, !isOpenNote, buttons, labels, () =>
        textLines(
          note.id,
          [
            note.from ? `From: ${note.from}` : '',
            note.date ? `Written: ${note.date}` : '',
            note.repo ? `Repo: ${note.repo}` : '',
            note.branch ? `Branch: ${note.branch}` : '',
            note.closed ? `${note.state === 'canceled' ? 'Canceled' : 'Done'}: ${note.closed}` : '',
          ],
          note.body ?? ''
        )
      )
    }

    // A section's rows, flat when they share one group, else each group under a title that folds.
    const grouped = <T,>(section: string, rows: T[], groupOf: (row: T) => string, draw: (row: T) => unknown) => {
      const groups = byGroup(rows, groupOf)

      if (groups.length <= 1) {
        return rows.map(draw)
      }

      return groups.map(([name, members]) => {
        const key = `${section}|${name}`
        const isOpen = sections[key] ?? true

        return (
          <Box key={`group-${key}`} flexDirection="column" paddingLeft={2}>
            <Button key={`group-${section}-${name}`} plain onPress={() => void update($, openSections, all => ({ ...all, [key]: !isOpen }))}>
              <Text>{`${isOpen ? '▾' : '▸'} ${name} (${members.length})`}</Text>
            </Button>
            {isOpen && (members.map(draw) as never)}
          </Box>
        )
      })
    }

    const section = <T,>(id: string, title: string, isOpenAtFirst: boolean, rows: T[], groupOf: (row: T) => string, draw: (row: T) => unknown) => {
      const isOpen = sections[id] ?? isOpenAtFirst

      return (
        <Box key={`section-${id}`} flexDirection="column" marginTop={1}>
          <Button key={id} plain onPress={() => void update($, openSections, all => ({ ...all, [id]: !isOpen }))}>
            <Text bold>{`${isOpen ? '▾' : '▸'} ${title} (${rows.length})`}</Text>
          </Button>
          {isOpen && rows.length === 0 && (
            <Box paddingLeft={2}>
              <Text dimColor>nothing</Text>
            </Box>
          )}
          {isOpen && (grouped(id, rows, groupOf, draw) as never)}
        </Box>
      )
    }

    const byNext = (one: Reminder, other: Reminder) => (one.next ?? one.on ?? '').localeCompare(other.next ?? other.on ?? '')
    const byClosed = (one: { closed?: string }, other: { closed?: string }) => (other.closed ?? '').localeCompare(one.closed ?? '')

    const remindersTab = () => {
      const all = shownReminders ?? []

      return [
        section('now', 'Now', true, all.filter(one => reminderSection(one) === 'now').sort(byNext), reminderGroup, one => reminderRow(one, 'yellow')),
        section('upcoming', 'Upcoming', true, all.filter(one => reminderSection(one) === 'upcoming').sort(byNext), reminderGroup, one => reminderRow(one, 'cyan')),
        section('past', 'Past', false, all.filter(one => reminderSection(one) === 'past').sort(byClosed), reminderGroup, one => reminderRow(one, 'gray')),
      ]
    }

    const handoffsTab = () => {
      const all = shownHandoffs ?? []
      const byDate = (one: Handoff, other: Handoff) => (other.date ?? '').localeCompare(one.date ?? '')

      return [
        section('open-notes', 'Open', true, all.filter(note => note.state === 'open').sort(byDate), handoffGroup, note => handoffRow(note, 'yellow')),
        section('done-notes', 'Done', false, all.filter(note => note.state !== 'open').sort(byClosed), handoffGroup, note => handoffRow(note, 'gray')),
      ]
    }

    const loaded = current === 'reminders' ? shownReminders : shownHandoffs
    const tabLabel = (source: Source) =>
      source === 'reminders' ? `Reminders (${remindersCount}${due > 0 ? `, ${due} now` : ''})` : `Handoffs (${open} open)`

    return (
      <Box flexDirection="column">
        {found.length > 1 && (
          <Box flexDirection="row" gap={2}>
            {found.map(source => (
              <Button key={`tab-${source}`} plain onPress={() => void update($, tab, () => source)}>
                {source === current ? <Text bold underline>{tabLabel(source)}</Text> : <Text dimColor>{tabLabel(source)}</Text>}
              </Button>
            ))}
          </Box>
        )}
        {found.length === 0 && <Text dimColor>Neither the reminders nor the handoff skill is installed.</Text>}
        <Box flexDirection="row" justifyContent="space-between">
          <Text dimColor>
            {trouble !== '' ? `Could not read them: ${truncate(trouble, width - 30)}` : loaded === null ? 'Loading…' : ''}
          </Text>
          <Button key="refresh" label="refresh" onPress={() => void load($)} />
        </Box>
        {loaded !== null && ((current === 'reminders' ? remindersTab() : handoffsTab()) as never)}
      </Box>
    )
  })
}
