import {randomUUID} from 'crypto';
import {promises as fs} from 'fs';
import {hostname} from 'os';
import path from 'path';
import {setTimeout as sleep} from 'timers/promises';
import {inject, injectable} from 'inversify';
import {TYPES} from '../types.js';
import Config from './config.js';
import PlayerManager from '../managers/player.js';

// Several installs can share one bot token. They coordinate through two bot-owned messages in a private
// #bots-internal channel: a roster (install order = priority, first = preferred) and a heartbeat edited by
// whichever install is active. Only the active install logs in to the Discord gateway; standbys just poll
// the heartbeat over REST. Without that channel the bot runs on its own, exactly as before.
export const FAILOVER_CHANNEL_NAME = 'bots-internal';
// How far back to look for the two status messages, which other bots' chatter can push up the channel
const SCAN_MESSAGE_LIMIT = 1000;
// Re-scan now and then to catch duplicate status messages created by two installs at the same moment
const RESCAN_EVERY_TICKS = 15;
export const HEARTBEAT_SECONDS = 20;
// A heartbeat older than this means the active install is gone
export const TIMEOUT_SECONDS = 75;
// Longer than one heartbeat, so the active install sees a claim (and steps down or overrides it) before we log in
export const CLAIM_SETTLE_SECONDS = HEARTBEAT_SECONDS + 5;

const ROSTER_KIND = 'lnn-failover-roster';
const HEARTBEAT_KIND = 'lnn-failover-heartbeat';
const API = 'https://discord.com/api/v10';

export interface Instance {
  id: string;
  name: string;
}

export interface Heartbeat extends Instance {
  state: 'active' | 'claiming' | 'stopped';
  // Playing, or paused with a song loaded: a higher-priority install waits for this to clear before taking back
  busy: boolean;
}

export interface FailoverView {
  roster: Instance[];
  heartbeat?: Heartbeat;
  heartbeatAgeSeconds: number;
}

export type Role = 'standby' | 'active';
export type Decision = 'wait' | 'claim' | 'beat' | 'step-down';

/** Lower is preferred; installs missing from the roster rank last. */
export const priorityOf = (roster: Instance[], id: string) => {
  const index = roster.findIndex(instance => instance.id === id);
  return index === -1 ? Number.POSITIVE_INFINITY : index;
};

export const decide = (role: Role, self: Instance, view: FailoverView): Decision => {
  const {heartbeat} = view;
  const othersAlive = heartbeat !== undefined
    && heartbeat.id !== self.id
    && heartbeat.state !== 'stopped'
    && view.heartbeatAgeSeconds < TIMEOUT_SECONDS;

  if (!othersAlive) {
    return role === 'active' ? 'beat' : 'claim';
  }

  const otherIsHigher = priorityOf(view.roster, heartbeat.id) < priorityOf(view.roster, self.id);

  if (role === 'active') {
    // Another install took over while we were unreachable, or a higher one is claiming: hand over
    if (heartbeat.state === 'active' || otherIsHigher) {
      return 'step-down';
    }

    // A lower install thought we were gone; our heartbeat overrides its claim
    return 'beat';
  }

  if (otherIsHigher) {
    return 'wait';
  }

  // A lower install is in charge: take back only once it is idle, so music is never cut off
  return heartbeat.state === 'claiming' || !heartbeat.busy ? 'claim' : 'wait';
};

interface StatusMessage<T> {
  id: string;
  data: T;
}

interface StatusMessages {
  roster?: StatusMessage<{instances: Instance[]}>;
  heartbeat?: StatusMessage<Heartbeat>;
  heartbeatAgeSeconds: number;
  duplicates: string[];
}

class DiscordApiError extends Error {
  constructor(message: string, readonly status: number) {
    super(message);
  }
}

interface DiscordMessage {
  id: string;
  content: string;
  timestamp: string;
  edited_timestamp: string | null;
  author: {id: string};
}

const parseStatus = (content: string): {kind?: string} & Record<string, unknown> | undefined => {
  const match = /```json\n(.+)\n```/s.exec(content);
  if (!match) {
    return undefined;
  }

  try {
    return JSON.parse(match[1]) as {kind?: string} & Record<string, unknown>;
  } catch {
    return undefined;
  }
};

// Snowflakes grow over time: the shorter/smaller id is the older message
const olderFirst = (a: DiscordMessage, b: DiscordMessage) => a.id.length - b.id.length || a.id.localeCompare(b.id);

/**
 * Picks the oldest roster and heartbeat message by the bot (the canonical ones) and lists any extra copies,
 * which can appear if two installs created the message at the same moment.
 */
export const readStatusMessages = (messages: DiscordMessage[], botId: string, serverNow: number): StatusMessages => {
  const result: StatusMessages = {heartbeatAgeSeconds: Number.POSITIVE_INFINITY, duplicates: []};

  for (const message of [...messages].sort(olderFirst)) {
    if (message.author.id !== botId) {
      continue;
    }

    const status = parseStatus(message.content);
    if (status?.kind === ROSTER_KIND) {
      if (result.roster) {
        result.duplicates.push(message.id);
      } else {
        result.roster = {id: message.id, data: {instances: (status.instances as Instance[]) ?? []}};
      }
    } else if (status?.kind === HEARTBEAT_KIND) {
      if (result.heartbeat) {
        result.duplicates.push(message.id);
      } else {
        const {id, name, state, busy} = status as unknown as Heartbeat;
        result.heartbeat = {id: message.id, data: {id, name, state, busy}};
        // Discord's clock on both sides, so install clocks don't matter
        result.heartbeatAgeSeconds = (serverNow - Date.parse(message.edited_timestamp ?? message.timestamp)) / 1000;
      }
    }
  }

  return result;
};

export const formatRoster = (instances: Instance[]) => [
  '**LnnMusicBot installs** in priority order (first is preferred):',
  ...instances.map((instance, index) => `${index + 1}. ${instance.name}`),
  '-# Managed by the bot for failover. Don\'t edit or delete.',
  '```json',
  JSON.stringify({kind: ROSTER_KIND, instances}),
  '```',
].join('\n');

export const formatHeartbeat = (heartbeat: Heartbeat) => {
  const status = {
    active: `🟢 running on **${heartbeat.name}**${heartbeat.busy ? ' (playing)' : ''}`,
    claiming: `🟡 **${heartbeat.name}** is taking over`,
    stopped: `⚪ stopped on **${heartbeat.name}**, waiting for a backup`,
  }[heartbeat.state];

  return [
    `**LnnMusicBot**: ${status}`,
    '-# Managed by the bot for failover. Don\'t edit or delete.',
    '```json',
    // `at` makes every edit change the content, so Discord always bumps edited_timestamp
    JSON.stringify({kind: HEARTBEAT_KIND, ...heartbeat, at: new Date().toISOString()}),
    '```',
  ].join('\n');
};

@injectable()
export default class Failover {
  private readonly token: string;
  private readonly dataDir: string;
  private readonly playerManager: PlayerManager;
  private botId = '';
  private channelId = '';
  private self: Instance = {id: '', name: ''};
  private role: Role = 'standby';
  // Canonical status message ids, found by scanning the channel; undefined forces a scan
  private messageIds?: {roster?: string; heartbeat?: string};
  private ticksSinceScan = 0;
  private stopping = false;

  constructor(@inject(TYPES.Config) config: Config, @inject(TYPES.Managers.Player) playerManager: PlayerManager) {
    this.token = config.DISCORD_TOKEN;
    this.dataDir = config.DATA_DIR;
    this.playerManager = playerManager;
  }

  /**
   * Starts the bot right away when there is no #bots-internal channel. Otherwise joins the failover group and
   * starts the bot only once this install is the one that should be active.
   */
  async run(startBot: () => Promise<void>): Promise<void> {
    const channelId = await this.findStatusChannel().catch((error: unknown) => {
      console.warn('Failover: could not look for the status channel, running on our own:', error);
      return undefined;
    });

    if (!channelId) {
      await startBot();
      return;
    }

    this.channelId = channelId;
    this.self = await this.loadIdentity();
    console.log(`Failover on (#${FAILOVER_CHANNEL_NAME}): this install is "${this.self.name}"; checking which install should be active...`);

    for (const signal of ['SIGTERM', 'SIGINT'] as const) {
      // `on`, not `once`: libraries built on signal-exit (e.g. ora, used at login) re-raise the signal, and with
      // no listener left that second signal would kill the process before the 'stopped' status is written
      process.on(signal, () => {
        if (!this.stopping) {
          this.stopping = true;
          void this.shutDown();
        }
      });
    }

    void this.loop(startBot);
  }

  private async loop(startBot: () => Promise<void>): Promise<never> {
    for (;;) {
      try {
        // eslint-disable-next-line no-await-in-loop
        await this.tick(startBot);
      } catch (error: unknown) {
        console.warn('Failover check failed, retrying:', error instanceof Error ? error.message : error);
      }

      // eslint-disable-next-line no-await-in-loop
      await sleep(HEARTBEAT_SECONDS * 1000);
    }
  }

  private async tick(startBot: () => Promise<void>) {
    let status = await this.readStatus();

    if (priorityOf(status.roster?.data.instances ?? [], this.self.id) === Number.POSITIVE_INFINITY) {
      const instances = [...(status.roster?.data.instances ?? []), this.self];
      await this.writeMessage(status.roster?.id, formatRoster(instances));
      console.log(`Failover: registered "${this.self.name}" as install #${instances.length}`);
      status = await this.readStatus();
    }

    const view = this.toView(status);
    const decision = decide(this.role, this.self, view);

    if (decision === 'beat') {
      await this.writeHeartbeat(status, 'active');
    } else if (decision === 'step-down') {
      console.log(`Failover: "${view.heartbeat?.name ?? 'another install'}" is taking over; stepping down to standby`);
      process.exit(0);
    } else if (decision === 'claim') {
      await this.claim(status, view, startBot);
    }
  }

  private async claim(status: StatusMessages, view: FailoverView, startBot: () => Promise<void>) {
    await this.writeHeartbeat(status, 'claiming');

    // Alone in the roster: nobody to wait for
    if (view.roster.length > 1) {
      await sleep(CLAIM_SETTLE_SECONDS * 1000);
    }

    const after = await this.readStatus();
    if (after.heartbeat?.data.id !== this.self.id) {
      return;
    }

    await this.writeHeartbeat(after, 'active');
    this.role = 'active';
    console.log(`Failover: "${this.self.name}" is now the active install`);

    try {
      await startBot();
    } catch (error: unknown) {
      console.error('Failover: starting the bot failed:', error);
      process.exit(1);
    }
  }

  private async shutDown() {
    if (this.role === 'active') {
      // Lets a backup take over right away instead of after the timeout
      await Promise.race([
        this.readStatus().then(async status => this.writeHeartbeat(status, 'stopped')),
        sleep(3000),
      ]).catch(() => undefined);
    }

    process.exit(0);
  }

  private toView(status: StatusMessages): FailoverView {
    return {
      roster: status.roster?.data.instances ?? [],
      heartbeat: status.heartbeat?.data,
      heartbeatAgeSeconds: status.heartbeatAgeSeconds,
    };
  }

  private async writeHeartbeat(status: StatusMessages, state: Heartbeat['state']) {
    const busy = state === 'active' && this.playerManager.isBusy();
    await this.writeMessage(status.heartbeat?.id, formatHeartbeat({...this.self, state, busy}));
  }

  private async writeMessage(messageId: string | undefined, content: string) {
    if (messageId) {
      await this.api('PATCH', `/channels/${this.channelId}/messages/${messageId}`, {content});
      return;
    }

    await this.api('POST', `/channels/${this.channelId}/messages`, {content});
    // Another install may have created the same message at the same moment: re-scan so all settle on the oldest
    this.messageIds = undefined;
  }

  private async readStatus(): Promise<StatusMessages> {
    const ids = this.messageIds;

    if (ids?.roster && ids.heartbeat && this.ticksSinceScan < RESCAN_EVERY_TICKS) {
      try {
        const roster = await this.api<DiscordMessage>('GET', `/channels/${this.channelId}/messages/${ids.roster}`);
        const heartbeat = await this.api<DiscordMessage>('GET', `/channels/${this.channelId}/messages/${ids.heartbeat}`);
        this.ticksSinceScan++;
        return readStatusMessages([roster.data, heartbeat.data], this.botId, heartbeat.serverNow);
      } catch (error: unknown) {
        // A status message was deleted: scan for (or later recreate) it
        if (!(error instanceof DiscordApiError && error.status === 404)) {
          throw error;
        }
      }
    }

    return this.scanStatus();
  }

  private async scanStatus(): Promise<StatusMessages> {
    const messages: DiscordMessage[] = [];
    let serverNow: number | undefined;
    let before = '';

    while (messages.length < SCAN_MESSAGE_LIMIT) {
      // eslint-disable-next-line no-await-in-loop
      const page = await this.api<DiscordMessage[]>('GET', `/channels/${this.channelId}/messages?limit=100${before ? `&before=${before}` : ''}`);
      serverNow ??= page.serverNow;
      messages.push(...page.data);

      if (page.data.length < 100) {
        break;
      }

      // Pages come newest first
      before = page.data[page.data.length - 1].id;
    }

    const status = readStatusMessages(messages, this.botId, serverNow ?? Date.now());

    for (const duplicate of status.duplicates) {
      // eslint-disable-next-line no-await-in-loop
      await this.api('DELETE', `/channels/${this.channelId}/messages/${duplicate}`).catch(() => undefined);
    }

    this.messageIds = {roster: status.roster?.id, heartbeat: status.heartbeat?.id};
    this.ticksSinceScan = 0;
    return status;
  }

  private async findStatusChannel(): Promise<string | undefined> {
    this.botId = (await this.api<{id: string}>('GET', '/users/@me')).data.id;
    const {data: guilds} = await this.api<Array<{id: string}>>('GET', '/users/@me/guilds');

    for (const guild of guilds) {
      // eslint-disable-next-line no-await-in-loop
      const {data: channels} = await this.api<Array<{id: string; name: string; type: number}>>('GET', `/guilds/${guild.id}/channels`);
      const channel = channels.find(candidate => candidate.type === 0 && candidate.name === FAILOVER_CHANNEL_NAME);

      if (channel) {
        try {
          // eslint-disable-next-line no-await-in-loop
          await this.api('GET', `/channels/${channel.id}/messages?limit=1`);
          return channel.id;
        } catch (error: unknown) {
          console.warn(`Failover: found #${FAILOVER_CHANNEL_NAME} but the bot can't read it (give it View Channel, Send Messages and Read Message History there). Running on our own:`, error instanceof Error ? error.message : error);
          return undefined;
        }
      }
    }

    console.log(`Failover off: no #${FAILOVER_CHANNEL_NAME} channel found, running as the only install.`);
    return undefined;
  }

  private async loadIdentity(): Promise<Instance> {
    const file = path.join(this.dataDir, 'failover-instance.json');
    let id: string;

    try {
      ({id} = JSON.parse(await fs.readFile(file, 'utf8')) as {id: string});
    } catch {
      id = randomUUID();
      await fs.writeFile(file, JSON.stringify({id}));
    }

    const configuredName = process.env.INSTANCE_NAME?.trim();
    const name = (configuredName ? configuredName : hostname()).slice(0, 40);
    return {id, name};
  }

  private async api<T = unknown>(method: string, route: string, body?: unknown): Promise<{data: T; serverNow: number}> {
    for (;;) {
      // eslint-disable-next-line no-await-in-loop
      const response = await fetch(`${API}${route}`, {
        method,
        headers: {Authorization: `Bot ${this.token}`, ...(body ? {'Content-Type': 'application/json'} : {})},
        body: body ? JSON.stringify(body) : undefined,
      });

      if (response.status === 429) {
        // eslint-disable-next-line no-await-in-loop
        const {retry_after: retryAfter} = await response.json() as {retry_after: number};
        // eslint-disable-next-line no-await-in-loop
        await sleep(Math.ceil(retryAfter * 1000));
        continue;
      }

      if (!response.ok) {
        throw new DiscordApiError(`${method} ${route.split('?')[0]}: HTTP ${response.status}`, response.status);
      }

      const serverNow = Date.parse(response.headers.get('date') ?? '') || Date.now();
      // eslint-disable-next-line no-await-in-loop
      const data = response.status === 204 ? undefined : await response.json() as unknown;
      return {data: data as T, serverNow};
    }
  }
}
