import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';

import 'core/jobs.dart';
import 'core/library.dart';
import 'core/log.dart';
import 'core/settings.dart';

/// Developer check (SABLE_BENCH=<books folder>): scans the folder, then turns
/// the "mouse wheel" over the library and logs how long frames take.
Future<void> runScrollBench(String folder) async {
  Settings.I.folders = [LibFolder(folder)];
  Settings.I.tileSize = double.tryParse(Platform.environment['SABLE_BENCH_TILE'] ?? '') ?? 112;
  Settings.I.gridStyle = Platform.environment['SABLE_BENCH_STYLE'] ?? Settings.I.gridStyle;
  Library.I.scan();
  await Future<void>.delayed(const Duration(seconds: 1));
  final until = DateTime.now().add(const Duration(minutes: 10));
  while ((Jobs.I.current != null || Jobs.I.queue.isNotEmpty) && DateTime.now().isBefore(until)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  await Future<void>.delayed(const Duration(seconds: 2));
  ScrollableState? grid;
  void visit(Element e) {
    if (e is StatefulElement && e.state is ScrollableState) {
      final s = e.state as ScrollableState;
      if (s.position.axis == Axis.vertical && (grid == null || s.position.maxScrollExtent > grid!.position.maxScrollExtent)) grid = s;
    }
    e.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  final pos = grid?.position;
  if (pos == null) {
    AppLog.I.info('BENCH no scrollable');
    exit(1);
  }
  final timings = <FrameTiming>[];
  void cb(List<FrameTiming> t) => timings.addAll(t);
  SchedulerBinding.instance.addTimingsCallback(cb);
  final sw = Stopwatch()..start();
  // Slow notches, then a fast spin, then back up.
  for (var i = 0; i < 40; i++) {
    pos.pointerScroll(53);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }
  for (var i = 0; i < 120; i++) {
    pos.pointerScroll(53);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  for (var i = 0; i < 80; i++) {
    pos.pointerScroll(-53);
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  await Future<void>.delayed(const Duration(seconds: 1));
  SchedulerBinding.instance.removeTimingsCallback(cb);
  final build = timings.map((t) => t.buildDuration.inMicroseconds / 1000).toList()..sort();
  double pc(List<double> l, double q) => l.isEmpty ? 0 : l[(l.length * q).floor().clamp(0, l.length - 1)];
  final slow = build.where((b) => b > 8).length;
  final msg = 'BENCH tile=${Settings.I.tileSize} books=${Library.I.books.length} frames=${timings.length} in ${sw.elapsedMilliseconds} ms '
      'build p50=${pc(build, .5).toStringAsFixed(2)} p90=${pc(build, .9).toStringAsFixed(2)} p99=${pc(build, .99).toStringAsFixed(2)} '
      'max=${build.isEmpty ? 0 : build.last.toStringAsFixed(2)} over8ms=$slow end=${pos.pixels.round()}';
  stdout.writeln(msg);
  AppLog.I.info(msg);
  exit(0);
}
