import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:json_annotation/json_annotation.dart';
import 'package:tangent/modules/rpg/base.dart';

part "data.g.dart";

typedef Map<String, dynamic> _ToJson<T>(T t);
typedef T _FromJson<T>(Map<String, dynamic> m);

class RpgTable<T extends RpgTableElm> {
  String name;
  _ToJson<T> elmToJson;
  _FromJson<T> elmFromJson;
  RpgTable(this.name, this.elmToJson, this.elmFromJson);

  Future load() async {
    var playersDir = Directory("db/rpg/$name");
    if (!await playersDir.exists()) playersDir = await playersDir.create(recursive: true);

    await Future.wait((await playersDir.list().toList()).map((p) async {
      if (p is File) {
        var n = int.tryParse(p.uri.pathSegments.last);
        if (n == null) return;
        m[n] = elmFromJson(jsonDecode(await p.readAsString()))
          ..table = this
          ..id = n;
      }
    }));
  }

  Map<int, T> m = {};

  var saveReq = StreamController<Null>.broadcast();
  var saveQueue = Set<int>();
  var saveDone = Completer<Null>();

  void saveTask() async {
    while (!saveReq.isClosed) {
      try {
        await saveReq.stream.first;
      } on StateError {
        break;
      }

      await Future.delayed(Duration(milliseconds: 100));

      while (saveQueue.isNotEmpty) {
        var toSave = saveQueue.toList();
        saveQueue.clear();

        await Future.wait(toSave.map((id) =>
          File("db/rpg/$name/$id").writeAsString(jsonEncode(elmToJson(m[id])))
        ));
      }
    }

    saveDone.complete();
  }

  Future close() async {
    await saveReq.close();
    await saveDone.future;
  }
}

class RpgTableElm {
  @JsonKey(ignore: true) int id;
  @JsonKey(ignore: true) RpgTable table;
  void save() {
    table.saveQueue.add(id);
    table.saveReq.add(null);
  }
}

@JsonSerializable() class ExchangeData {
  ExchangeData();
  int nextUpdate = 0;
  Map<String, num> rates = {};

  static Future<ExchangeData> load() async {
    var exf = File("db/rpg/exchange");
    if (await exf.exists()) {
      return ExchangeData.fromJson(jsonDecode(await exf.readAsString()));
    } else {
      return ExchangeData();
    }
  }

  Future save() async {
    await File("db/rpg/exchange").writeAsString(jsonEncode(toJson()));
  }

  factory ExchangeData.fromJson(Map<String, dynamic> json) => _$ExchangeDataFromJson(json);
  Map<String, dynamic> toJson() => _$ExchangeDataToJson(this);
}

class RpgDB {
  Future load() async {
    await Future.wait([
      players
    ].map((m) async {
      await m.load();
      m.saveTask();
    }));

    exchange = await ExchangeData.load();
  }

  var players = RpgTable("players", _$PlayerToJson, _$PlayerFromJson);

  ExchangeData exchange;

  Future close() async {
    await Future.wait([
      players.close(),
      // ...
    ]);
  }
}

@JsonSerializable() class Item {
  Item.nil();
  Item.int(this.id, [int count, this.meta]) {
    count ??= 1;
    this.count = BigInt.from(count);
    meta ??= {};
  }
  Item(this.id, [this.count, this.meta]) {
    count ??= BigInt.from(1);
    meta ??= {};
  }

  String id;
  BigInt count;
  Map<String, String> meta;

  Item copy({String id, BigInt count, Map<String, String> meta}) => Item(
    id ?? this.id,
    count ?? this.count,
    meta ?? this.meta,
  );

  toString() => "Item($id,$count,$meta)";

  factory Item.fromJson(Map<String, dynamic> json) => _$ItemFromJson(json);
  Map<String, dynamic> toJson() => _$ItemToJson(this);
}

@JsonSerializable() class RefineProgress {
  RefineProgress();
  String name;
  int time;
  List<Item> items;

  factory RefineProgress.fromJson(Map<String, dynamic> json) => _$RefineProgressFromJson(json);
  Map<String, dynamic> toJson() => _$RefineProgressToJson(this);
}

@JsonSerializable() class Player extends RpgTableElm {
  Player();
  int level = 0;
  List<Item> items = [];
  Map<String, int> cooldowns = {};
  Map<String, String> meta = {};
  int ban;
  int lastMsgTime;
  String lastMsgText;
  double spam;
  int strike = 0;
  RefineProgress refineProgress;

  BigInt getItemCount(String name) => items.fold(BigInt.from(0), (s, e) => e.id != name ? s : s + e.count);

  bool getCooldown(String name) {
    cooldowns ??= {};
    if (!cooldowns.containsKey(name)) return false;
    if (new DateTime.now().microsecondsSinceEpoch > cooldowns[name]) {
      cooldowns.remove(name);
      save();
      return false;
    }
    return true;
  }

  double getCooldownDelta(String name) {
    cooldowns ??= {};
    if (!cooldowns.containsKey(name)) return double.negativeInfinity;
    return (cooldowns[name] - new DateTime.now().microsecondsSinceEpoch) / 1000000.0;
  }

  void setCooldown(String name, double offset) {
    cooldowns ??= {};
    cooldowns[name] = new DateTime.now().microsecondsSinceEpoch + (offset * 1000000).toInt();
    save();
  }

  bool isBanned() => ban != null && DateTime.now().millisecondsSinceEpoch < ban;

  void applySpam(String text) {
    if (ban != null && new DateTime.now().millisecondsSinceEpoch >= ban) ban = null;
    lastMsgTime ??= new DateTime.now().millisecondsSinceEpoch - 100000;
    spam ??= 0.0;
    spam = max(0.0, (spam - ((new DateTime.now().millisecondsSinceEpoch - lastMsgTime) / 1000)) + (lastMsgText == text ? 2.5 : 1.5));
    lastMsgText = text;
    if (spam > 3) {
      ban = new DateTime.now().millisecondsSinceEpoch + 120000;
      strike = (strike ?? 0) + 1;
    }
    lastMsgTime = new DateTime.now().millisecondsSinceEpoch;
  }

  factory Player.fromJson(Map<String, dynamic> json) => _$PlayerFromJson(json);
  Map<String, dynamic> toJson() => _$PlayerToJson(this);
}