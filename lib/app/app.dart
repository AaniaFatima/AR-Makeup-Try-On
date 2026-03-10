import 'package:flutter/material.dart';
import 'router.dart';

class AppRoot extends StatelessWidget {
  const AppRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'AR Makeup Try-On',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter,
    );
  }
}
