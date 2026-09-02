// PUBLIC (open-core) build module list — no game-system modules. The publish
// script copies this over game_systems.dart and deletes lib/fuzion/ +
// lib/screens/fuzion/. See scripts/publish-public.sh.

import 'game_systems_api.dart';

export 'game_systems_api.dart';

final List<GameSystemModule> gameSystemModules = <GameSystemModule>[];
