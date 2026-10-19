// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: prefer_initializing_formals

import 'package:get/get_core/src/get_main.dart';
import 'package:get/get_navigation/src/extension_navigation.dart';
import 'package:material_ui/material_ui.dart' hide PopScope;

abstract class PopScopeState<T extends StatefulWidget> extends State<T>
    implements PopEntry<Object> {
  ModalRoute<dynamic>? _route;

  @override
  void onPopInvoked(bool didPop) {}

  @override
  late final ValueNotifier<bool> canPopNotifier;

  bool get initCanPop => true;

  @override
  void initState() {
    super.initState();
    canPopNotifier = ValueNotifier<bool>(initCanPop);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 注册到本 widget 实际所在的 route，而不是全局的 Get.routing.route：
    // 分屏 pane 里的 PopScope 必须作用于 pane 自己的 Navigator，
    // 否则会污染根导航的 popDisposition，同时 pane 内的拦截也会失效。
    final rawRoute = ModalRoute.of(context) ?? Get.routing.route;
    final route = rawRoute is ModalRoute ? rawRoute : null;
    if (!identical(route, _route)) {
      _route?.unregisterPopEntry(this);
      _route = route?..registerPopEntry(this);
    }
  }

  @override
  void dispose() {
    _route?.unregisterPopEntry(this);
    _route = null;
    canPopNotifier.dispose();
    super.dispose();
  }
}

// ignore: camel_case_types
typedef popScope = PopScope;

class PopScope extends StatefulWidget {
  const PopScope({
    super.key,
    required this.child,
    this.canPop = true,
    required this.onPopInvokedWithResult,
  });

  final Widget child;

  final PopInvokedWithResultCallback<Object> onPopInvokedWithResult;

  final bool canPop;

  @override
  State<PopScope> createState() => _PopScopeState();
}

class _PopScopeState<T extends PopScope> extends PopScopeState<T> {
  @override
  bool get initCanPop => widget.canPop;

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    widget.onPopInvokedWithResult(didPop, result);
  }

  @override
  void didUpdateWidget(T oldWidget) {
    super.didUpdateWidget(oldWidget);
    canPopNotifier.value = widget.canPop;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
