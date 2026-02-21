import 'package:stanza_sqlite/stanza_sqlite.dart';

/// FTS5 index for full-text search over episodic memory content.
///
/// Uses external content mode with SQLite's implicit `rowid` (not our TEXT
/// ULID primary key). FTS5 requires an INTEGER rowid; TEXT PKs don't alias
/// `rowid`, so we point at the implicit one.
const episodesFts = Fts5Index(
  sourceTable: 'episodes',
  columns: ['content'],
  tokenize: 'porter unicode61',
);

/// FTS5 index for full-text search over semantic memory content.
const memoriesFts = Fts5Index(
  sourceTable: 'memories',
  columns: ['content'],
  tokenize: 'porter unicode61',
);
