import 'package:flutter/material.dart';

import '../services/subtitles.dart';

/// Offered as one-tap choices; any other code can be typed.
const _common = <(String, String)>[
  ('en', 'English'),
  ('hu', 'Hungarian'),
  ('de', 'German'),
  ('es', 'Spanish'),
  ('fr', 'French'),
  ('it', 'Italian'),
  ('pt', 'Portuguese'),
  ('ja', 'Japanese'),
];

/// [languages] (comma-separated codes) for people: the names of common
/// languages, other codes as they are. `en,hu,pt-BR` reads
/// "English, Hungarian, pt-BR".
String subtitleLanguagesLabel(String languages) {
  final names = {for (final (code, name) in _common) code: name};
  return languages
      .split(',')
      .map((code) => code.trim())
      .where((code) => code.isNotEmpty)
      .map((code) => names[code.toLowerCase()] ?? code)
      .join(', ');
}

/// Asks for subtitle languages, starting from [initialValue]. Returns the
/// tidied list (see [normalizeSubtitleLanguages]), or null when cancelled.
Future<String?> showSubtitleLanguagesDialog(
  BuildContext context, {
  required String initialValue,
}) => showDialog<String>(
  context: context,
  builder: (_) => SubtitleLanguagesDialog(initialValue: initialValue),
);

class SubtitleLanguagesDialog extends StatefulWidget {
  const SubtitleLanguagesDialog({super.key, required this.initialValue});

  final String initialValue;

  @override
  State<SubtitleLanguagesDialog> createState() =>
      _SubtitleLanguagesDialogState();
}

class _SubtitleLanguagesDialogState extends State<SubtitleLanguagesDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialValue);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
  }

  void _onChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  List<String> get _codes =>
      _controller.text
          .split(',')
          .map((code) => code.trim())
          .where((code) => code.isNotEmpty)
          .toList();

  void _toggle(String code, bool selected) {
    final codes = _codes..remove(code);
    if (selected) codes.add(code);
    _controller.text = codes.join(', ');
  }

  void _save() {
    if (_formKey.currentState!.validate()) {
      Navigator.pop(context, normalizeSubtitleLanguages(_controller.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final codes = _codes;
    return AlertDialog(
      title: const Text('Subtitle languages'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 2,
                children: [
                  for (final (code, name) in _common)
                    FilterChip(
                      label: Text(name),
                      selected: codes.contains(code),
                      onSelected: (selected) => _toggle(code, selected),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _controller,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Language codes',
                  helperText:
                      'Separate codes with commas: en, hu, de. '
                      'en.* also gets en-US and en-GB.',
                  helperMaxLines: 2,
                ),
                validator: (value) {
                  try {
                    normalizeSubtitleLanguages(value ?? '');
                    return null;
                  } on FormatException catch (error) {
                    return error.message;
                  }
                },
                onFieldSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
