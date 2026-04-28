'use strict';

const { pool, tableColumns, clearColumnCache } = require('./db');

async function tableExists(tableName) {
  const [rows] = await pool.execute(`
    SELECT COUNT(*) AS n
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_name = ?
  `, [tableName]);
  return Number(rows[0]?.n || 0) > 0;
}

// Wrapper : vérifie l'existence puis délègue le cache à db.js/tableColumns
async function getColumns(tableName) {
  if (!(await tableExists(tableName))) return [];
  return tableColumns(tableName);
}

function has(columns, name) {
  return columns.includes(name);
}

async function getUserWithGlobalRole(idUser) {
  const userCols = await getColumns('USER');
  const levelCols = await getColumns('USER_LEVEL');

  if (!userCols.length) return null;

  const select = [
    'u.id_user',
    has(userCols, 'nickname') ? 'u.nickname' : 'NULL AS nickname',
    has(userCols, 'username') ? 'u.username' : 'NULL AS username',
    has(userCols, 'id_user_level') ? 'u.id_user_level' : 'NULL AS id_user_level',
    has(userCols, 'auth') ? 'u.auth' : 'NULL AS auth',
    has(userCols, 'tz') ? 'u.tz' : 'NULL AS tz',
    has(userCols, 'birthday') ? 'u.birthday' : 'NULL AS birthday',
    has(userCols, 'fortniteid') ? 'u.fortniteid' : 'NULL AS fortniteid',
    has(userCols, 'last_login') ? 'u.last_login' : 'NULL AS last_login',
    has(userCols, 'creation_date') ? 'u.creation_date' : 'NULL AS creation_date'
  ];

  let join = '';
  if (levelCols.length && has(userCols, 'id_user_level') && has(levelCols, 'id_user_level')) {
    select.push(has(levelCols, 'level') ? 'ul.level AS global_level' : 'NULL AS global_level');
    select.push(has(levelCols, 'description') ? 'ul.description AS global_role' : 'NULL AS global_role');
    join = 'LEFT JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level';
  } else {
    select.push('NULL AS global_level');
    select.push('NULL AS global_role');
  }

  const [rows] = await pool.execute(`
    SELECT ${select.join(', ')}
    FROM USER u
    ${join}
    WHERE u.id_user = ?
    LIMIT 1
  `, [idUser]);

  return rows[0] || null;
}

async function getUserById(idUser) {
  const [rows] = await pool.execute(`
    SELECT *
    FROM USER
    WHERE id_user = ?
    LIMIT 1
  `, [idUser]);

  return rows[0] || null;
}

async function getUserChannels(idUser) {
  const ucCols = await getColumns('USER_CHANNEL');
  const channelCols = await getColumns('CHANNEL');

  if (!ucCols.length || !channelCols.length) return [];

  const select = [
    has(channelCols, 'id_channel') ? 'c.id_channel' : 'NULL AS id_channel',
    has(channelCols, 'name') ? 'c.name' : 'NULL AS name',
    has(channelCols, 'description') ? 'c.description' : 'NULL AS description',
    has(channelCols, 'topic') ? 'c.topic' : 'NULL AS topic',
    has(channelCols, 'auto_join') ? 'c.auto_join' : 'NULL AS auto_join',
    has(channelCols, 'chanmode') ? 'c.chanmode' : 'NULL AS chanmode',
    has(channelCols, 'id_user') ? 'c.id_user AS channel_owner_id' : 'NULL AS channel_owner_id',
    has(ucCols, 'level') ? 'uc.level AS channel_level' : 'NULL AS channel_level',
    has(ucCols, 'automode') ? 'uc.automode' : 'NULL AS automode',
    has(ucCols, 'greet') ? 'uc.greet' : 'NULL AS greet'
  ];

  const [rows] = await pool.execute(`
    SELECT ${select.join(', ')}
    FROM USER_CHANNEL uc
    JOIN CHANNEL c ON c.id_channel = uc.id_channel
    WHERE uc.id_user = ?
    ORDER BY c.name
  `, [idUser]);

  return rows;
}

async function getAllChannels() {
  const channelCols = await getColumns('CHANNEL');
  if (!channelCols.length) return [];

  const select = [
    has(channelCols, 'id_channel') ? 'id_channel' : 'NULL AS id_channel',
    has(channelCols, 'name') ? 'name' : 'NULL AS name',
    has(channelCols, 'description') ? 'description' : 'NULL AS description',
    has(channelCols, 'topic') ? 'topic' : 'NULL AS topic',
    has(channelCols, 'auto_join') ? 'auto_join' : 'NULL AS auto_join',
    has(channelCols, 'chanmode') ? 'chanmode' : 'NULL AS chanmode',
    has(channelCols, 'id_user') ? 'id_user AS channel_owner_id' : 'NULL AS channel_owner_id'
  ];

  const [rows] = await pool.query(`
    SELECT ${select.join(', ')}
    FROM CHANNEL
    ORDER BY name
  `);

  return rows;
}

async function getUserHostmasks(idUser) {
  if (await tableExists('USER_HOSTMASK')) {
    const cols = await getColumns('USER_HOSTMASK');

    const select = [
      has(cols, 'id_user_hostmask') ? 'id_user_hostmask' : 'NULL AS id_user_hostmask',
      has(cols, 'hostmask') ? 'hostmask' : 'NULL AS hostmask',
      has(cols, 'created_at') ? 'created_at' : 'NULL AS created_at'
    ];

    const [rows] = await pool.execute(`
      SELECT ${select.join(', ')}
      FROM USER_HOSTMASK
      WHERE id_user = ?
      ORDER BY ${has(cols, 'created_at') ? 'created_at DESC' : 'id_user_hostmask DESC'}
    `, [idUser]);

    return rows.filter(r => r.hostmask);
  }

  const user = await getUserById(idUser);
  const legacy = String(user?.hostmasks_legacy || '').trim();

  if (!legacy) return [];

  return legacy
    .split(/[,\s]+/)
    .map((h, idx) => ({
      id_user_hostmask: idx + 1,
      hostmask: h,
      created_at: null,
      legacy: true
    }))
    .filter(r => r.hostmask);
}

async function getChannelById(idChannel) {
  const channelCols = await getColumns('CHANNEL');
  if (!channelCols.length) return null;

  const select = [
    has(channelCols, 'id_channel') ? 'id_channel' : 'NULL AS id_channel',
    has(channelCols, 'name') ? 'name' : 'NULL AS name',
    has(channelCols, 'description') ? 'description' : 'NULL AS description',
    has(channelCols, 'topic') ? 'topic' : 'NULL AS topic',
    has(channelCols, 'auto_join') ? 'auto_join' : 'NULL AS auto_join',
    has(channelCols, 'chanmode') ? 'chanmode' : 'NULL AS chanmode',
    has(channelCols, 'id_user') ? 'id_user AS channel_owner_id' : 'NULL AS channel_owner_id',
    has(channelCols, 'tmdb_lang') ? 'tmdb_lang' : 'NULL AS tmdb_lang',
    has(channelCols, 'urltitle') ? 'urltitle' : 'NULL AS urltitle'
  ];

  const [rows] = await pool.execute(`
    SELECT ${select.join(', ')}
    FROM CHANNEL
    WHERE id_channel = ?
    LIMIT 1
  `, [idChannel]);

  return rows[0] || null;
}

async function userHasChannelAccess(idUser, idChannel) {
  const user = await getUserWithGlobalRole(idUser);

  const semanticLevel =
    typeof user?.global_level === 'number'
      ? user.global_level
      : Number.isFinite(Number(user?.id_user_level))
        ? Math.max(0, Number(user.id_user_level) - 1)
        : 999;

  if (semanticLevel <= 1) {
    return true;
  }

  const [rows] = await pool.execute(`
    SELECT COUNT(*) AS n
    FROM USER_CHANNEL
    WHERE id_user = ?
      AND id_channel = ?
  `, [idUser, idChannel]);

  return Number(rows[0]?.n || 0) > 0;
}

async function getChannelUsers(idChannel) {
  const ucCols = await getColumns('USER_CHANNEL');
  const userCols = await getColumns('USER');
  const levelCols = await getColumns('USER_LEVEL');

  if (!ucCols.length || !userCols.length) return [];

  const select = [
    'u.id_user',
    has(userCols, 'nickname') ? 'u.nickname' : 'NULL AS nickname',
    has(userCols, 'username') ? 'u.username' : 'NULL AS username',
    has(userCols, 'id_user_level') ? 'u.id_user_level' : 'NULL AS id_user_level',
    has(userCols, 'auth') ? 'u.auth' : 'NULL AS auth',
    has(ucCols, 'level') ? 'uc.level AS channel_level' : 'NULL AS channel_level',
    has(ucCols, 'automode') ? 'uc.automode' : 'NULL AS automode',
    has(ucCols, 'greet') ? 'uc.greet' : 'NULL AS greet'
  ];

  let joinLevel = '';
  if (levelCols.length && has(userCols, 'id_user_level') && has(levelCols, 'id_user_level')) {
    select.push(has(levelCols, 'level') ? 'ul.level AS global_level' : 'NULL AS global_level');
    select.push(has(levelCols, 'description') ? 'ul.description AS global_role' : 'NULL AS global_role');
    joinLevel = 'LEFT JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level';
  } else {
    select.push('NULL AS global_level');
    select.push('NULL AS global_role');
  }

  const [rows] = await pool.execute(`
    SELECT ${select.join(', ')}
    FROM USER_CHANNEL uc
    JOIN USER u ON u.id_user = uc.id_user
    ${joinLevel}
    WHERE uc.id_channel = ?
    ORDER BY uc.level ASC, u.nickname ASC
  `, [idChannel]);

  return rows;
}

async function getKnownChannelRelatedTables() {
  const [rows] = await pool.execute(`
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND (
        table_name LIKE '%CHANSET%'
        OR table_name LIKE '%CHANNEL%'
        OR table_name LIKE '%RESPONDER%'
        OR table_name LIKE '%QUOTE%'
      )
      AND table_name != 'CHANNEL'
    ORDER BY table_name
  `);

  return rows.map(r => r.table_name);
}


async function getAllUsersWithRoles() {
  const userCols = await getColumns('USER');
  const levelCols = await getColumns('USER_LEVEL');

  if (!userCols.length) return [];

  const select = [
    'u.id_user',
    has(userCols, 'nickname') ? 'u.nickname' : 'NULL AS nickname',
    has(userCols, 'username') ? 'u.username' : 'NULL AS username',
    has(userCols, 'id_user_level') ? 'u.id_user_level' : 'NULL AS id_user_level',
    has(userCols, 'auth') ? 'u.auth' : 'NULL AS auth',
    has(userCols, 'tz') ? 'u.tz' : 'NULL AS tz',
    has(userCols, 'birthday') ? 'u.birthday' : 'NULL AS birthday',
    has(userCols, 'fortniteid') ? 'u.fortniteid' : 'NULL AS fortniteid',
    has(userCols, 'last_login') ? 'u.last_login' : 'NULL AS last_login',
    has(userCols, 'creation_date') ? 'u.creation_date' : 'NULL AS creation_date'
  ];

  let joinLevel = '';

  if (levelCols.length && has(userCols, 'id_user_level') && has(levelCols, 'id_user_level')) {
    select.push(has(levelCols, 'level') ? 'ul.level AS global_level' : 'NULL AS global_level');
    select.push(has(levelCols, 'description') ? 'ul.description AS global_role' : 'NULL AS global_role');
    joinLevel = 'LEFT JOIN USER_LEVEL ul ON ul.id_user_level = u.id_user_level';
  } else {
    select.push('NULL AS global_level');
    select.push('NULL AS global_role');
  }

  const orderBy = joinLevel
    ? 'COALESCE(ul.level, u.id_user_level, 999)'
    : 'COALESCE(u.id_user_level, 999)';

  const [rows] = await pool.query(`
    SELECT ${select.join(', ')}
    FROM USER u
    ${joinLevel}
    ORDER BY
      ${orderBy} ASC,
      u.nickname ASC
  `);

  return rows;
}

async function getUserChannelCountMap() {
  if (!(await tableExists('USER_CHANNEL'))) return {};

  const [rows] = await pool.query(`
    SELECT id_user, COUNT(*) AS n
    FROM USER_CHANNEL
    GROUP BY id_user
  `);

  const out = {};
  for (const row of rows) {
    out[row.id_user] = Number(row.n || 0);
  }
  return out;
}


async function getCounts() {
  const out = {
    users: null,
    channels: null
  };

  try {
    const [u] = await pool.query('SELECT COUNT(*) AS n FROM USER');
    out.users = u[0]?.n ?? null;
  } catch (_) {}

  try {
    const [c] = await pool.query('SELECT COUNT(*) AS n FROM CHANNEL');
    out.channels = c[0]?.n ?? null;
  } catch (_) {}

  return out;
}


async function getCommands({ category = null, search = null, limit = 200 } = {}) {
  // PUBLIC_COMMANDS joined with USER (author) and PUBLIC_COMMANDS_CATEGORY
  const [catExists, cmdExists] = await Promise.all([
    tableExists('PUBLIC_COMMANDS_CATEGORY'),
    tableExists('PUBLIC_COMMANDS')
  ]);

  if (!cmdExists) return [];

  const userCols = await getColumns('USER');
  const catJoin  = catExists
    ? 'LEFT JOIN PUBLIC_COMMANDS_CATEGORY pcc ON pcc.id_public_commands_category = pc.id_public_commands_category'
    : '';
  const catSelect = catExists ? "pcc.description AS category" : "NULL AS category";
  const nickSelect = userCols.length ? 'u.nickname AS author_nick' : 'NULL AS author_nick';

  const conditions = [];
  const params = [];

  if (category && catExists) {
    conditions.push('pcc.description = ?');
    params.push(category);
  }

  if (search) {
    conditions.push('(pc.command LIKE ? OR pc.description LIKE ? OR pc.action LIKE ?)');
    const pat = `%${search.replace(/[%_]/g, '\$&')}%`;
    params.push(pat, pat, pat);
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  const [rows] = await pool.execute(`
    SELECT
      pc.id_public_commands,
      pc.command,
      pc.action,
      pc.description,
      pc.active,
      pc.hits,
      pc.creation_date,
      pc.id_user,
      ${nickSelect},
      ${catSelect}
    FROM PUBLIC_COMMANDS pc
    LEFT JOIN USER u ON u.id_user = pc.id_user
    ${catJoin}
    ${where}
    ORDER BY pc.hits DESC, pc.command ASC
    LIMIT ?
  `, [...params, limit]);

  return rows;
}

async function getCommandCategories() {
  if (!(await tableExists('PUBLIC_COMMANDS_CATEGORY'))) return [];

  const [rows] = await pool.query(`
    SELECT pcc.description AS category, COUNT(pc.id_public_commands) AS n
    FROM PUBLIC_COMMANDS_CATEGORY pcc
    LEFT JOIN PUBLIC_COMMANDS pc ON pc.id_public_commands_category = pcc.id_public_commands_category
    GROUP BY pcc.description
    ORDER BY pcc.description ASC
  `);

  return rows;
}


async function getQuotes({ channel = null, search = null, page = 1, perPage = 50 } = {}) {
  if (!(await tableExists('QUOTES'))) return { rows: [], total: 0 };

  const quoteCols   = await getColumns('QUOTES');
  const channelCols = await getColumns('CHANNEL');
  const userCols    = await getColumns('USER');

  if (!quoteCols.length) return { rows: [], total: 0 };

  const hasTs      = has(quoteCols, 'ts');
  const hasChannel = channelCols.length && has(quoteCols, 'id_channel');
  const hasUser    = userCols.length    && has(quoteCols, 'id_user');

  const conditions = [];
  const params     = [];

  if (channel && hasChannel) {
    conditions.push('c.name = ?');
    params.push(channel);
  }

  if (search) {
    conditions.push('q.quotetext LIKE ?');
    params.push(`%${search.replace(/[%_]/g, '\$&')}%`);
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';

  const countSql = `
    SELECT COUNT(*) AS n
    FROM QUOTES q
    ${hasChannel ? 'JOIN CHANNEL c ON c.id_channel = q.id_channel' : ''}
    ${hasUser    ? 'LEFT JOIN USER u ON u.id_user = q.id_user'     : ''}
    ${where}
  `;

  const offset  = (Math.max(1, page) - 1) * perPage;

  const rowsSql = `
    SELECT
      q.id_quotes,
      q.quotetext,
      q.id_user,
      ${hasTs      ? 'q.ts'                : 'NULL AS ts'},
      ${hasChannel ? 'c.name AS channel_name' : 'NULL AS channel_name'},
      ${hasUser    ? 'u.nickname AS author_nick' : 'NULL AS author_nick'}
    FROM QUOTES q
    ${hasChannel ? 'JOIN CHANNEL c ON c.id_channel = q.id_channel' : ''}
    ${hasUser    ? 'LEFT JOIN USER u ON u.id_user = q.id_user'     : ''}
    ${where}
    ORDER BY ${hasTs ? 'q.ts DESC' : 'q.id_quotes DESC'}
    LIMIT ? OFFSET ?
  `;

  const [[countRow], [rows]] = await Promise.all([
    pool.execute(countSql, params),
    pool.execute(rowsSql,  [...params, perPage, offset])
  ]);

  return { rows, total: Number(countRow[0]?.n || 0) };
}

async function getQuoteChannels() {
  if (!(await tableExists('QUOTES')) || !(await tableExists('CHANNEL'))) return [];

  const [rows] = await pool.query(`
    SELECT c.name, COUNT(q.id_quotes) AS n
    FROM CHANNEL c
    JOIN QUOTES q ON q.id_channel = c.id_channel
    GROUP BY c.name
    ORDER BY n DESC, c.name ASC
  `);

  return rows;
}


async function getNetworks() {
  const [netExists, srvExists] = await Promise.all([
    tableExists('NETWORK'),
    tableExists('SERVERS')
  ]);

  if (!netExists) return [];

  const netCols = await getColumns('NETWORK');
  const srvCols = srvExists ? await getColumns('SERVERS') : [];

  if (!netCols.length) return [];

  // Build per-network list with their servers
  const [nets] = await pool.query(`
    SELECT
      n.id_network,
      n.network_name
    FROM NETWORK n
    ORDER BY n.network_name ASC
  `);

  if (!nets.length) return [];

  if (!srvExists || !srvCols.length) {
    return nets.map(n => ({ ...n, servers: [] }));
  }

  const [srvs] = await pool.query(`
    SELECT
      s.id_server,
      s.id_network,
      s.server_hostname
    FROM SERVERS s
    ORDER BY s.id_network ASC, s.server_hostname ASC
  `);

  // Group servers by id_network
  const srvMap = {};
  for (const s of srvs) {
    if (!srvMap[s.id_network]) srvMap[s.id_network] = [];
    // server_hostname may be "host:port"
    const [host, port] = String(s.server_hostname || '').split(':');
    srvMap[s.id_network].push({
      id_server: s.id_server,
      hostname: host || s.server_hostname,
      port: port ? Number(port) : null,
      raw: s.server_hostname
    });
  }

  return nets.map(n => ({
    ...n,
    servers: srvMap[n.id_network] || []
  }));
}

module.exports = {
  tableExists,
  getColumns,
  getCommands,
  getCommandCategories,
  getQuotes,
  getQuoteChannels,
  getNetworks,
  getUserWithGlobalRole,
  getUserById,
  getUserChannels,
  getAllChannels,
  getChannelById,
  userHasChannelAccess,
  getChannelUsers,
  getKnownChannelRelatedTables,
  getAllUsersWithRoles,
  getUserChannelCountMap,
  getUserHostmasks,
  getCounts
};
