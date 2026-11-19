import 'package:flutter/services.dart';

class PriceInputFormatter extends TextInputFormatter {
  static final _pattern = RegExp(r'^\d{0,10}([.,]\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => _pattern.hasMatch(newValue.text) ? newValue : oldValue;
}

String? validatePrice(String? value) {
  final text = (value ?? '').replaceAll(',', '.');
  final number = double.tryParse(text);
  if (!RegExp(r'^\d{1,10}(\.\d{1,2})?$').hasMatch(text) ||
      number == null ||
      !number.isFinite ||
      number < 0) {
    return 'Укажите цену цифрами, не более 2 знаков после запятой';
  }
  return null;
}
