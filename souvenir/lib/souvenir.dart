library souvenir;

// v3 engine.
export 'src/engine.dart';

// v3 unified recall.
export 'src/recall.dart';

// v3 unified store.
export 'src/memory_store.dart';
export 'src/stored_memory.dart';
export 'src/in_memory_memory_store.dart';
export 'src/sqlite_memory_store.dart';

// Core interfaces and types.
export 'src/episode_store.dart';
export 'src/memory_component.dart';
export 'src/tokenizer.dart';
export 'src/embedding_provider.dart';
export 'src/ollama_embedding_provider.dart';
export 'src/llm_callback.dart';
export 'src/models/episode.dart';

// Memory components.
export 'src/durable/durable_memory.dart';
export 'src/durable/durable_memory_config.dart';
export 'src/task/task_memory.dart';
export 'src/task/task_memory_config.dart';
export 'src/environmental/environmental_memory.dart';
export 'src/environmental/environmental_memory_config.dart';

// Cellar-backed stores (episode store only — memory stores are unified).
export 'src/cellar_episode_store.dart';
export 'src/souvenir_cellar.dart';

// Legacy types — retained for Cellar store implementations and configs.
// Will be removed once Cellar stores are migrated to unified MemoryStore.
export 'src/task/task_item.dart';
export 'src/task/task_memory_store.dart';
export 'src/environmental/environmental_item.dart';
export 'src/environmental/environmental_memory_store.dart';
export 'src/environmental/cellar_environmental_memory_store.dart';
export 'src/task/cellar_task_memory_store.dart';
export 'src/durable/durable_memory_store.dart';

// Legacy v2 types — retained temporarily for old tests.
export 'src/budget.dart';
export 'src/labeled_recall.dart';
export 'src/mixer.dart';
