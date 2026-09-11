import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
export 'agent_page.dart';

const agentTabIndex = 2;
final agentPaneItem = PaneItemEntry(
  label: 'Agent',
  icon: Icons.auto_awesome_outlined,
  activeIcon: Icons.auto_awesome,
);

/// Stored values still belong to the upstream four-tab settings interface.
int agentInitialPage(Object? legacyValue) =>
    switch (int.tryParse(legacyValue.toString())) {
      0 => 0,
      1 => 1,
      2 => 3,
      3 => 4,
      _ => 0,
    };
