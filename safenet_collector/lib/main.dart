import 'package:flutter/material.dart';

import 'src/ui/home_screen.dart';

void main() {
  runApp(const SafeNetCollectorApp());
}

class SafeNetCollectorApp extends StatelessWidget {
  const SafeNetCollectorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SafeNet Collector',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
