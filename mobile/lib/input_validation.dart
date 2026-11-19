import 'package:flutter/services.dart';

class RussianPhoneInputFormatter extends TextInputFormatter {
  static final _allowed = RegExp(r'^\+?[0-9\s().-]*$');
  static final _nonDigit = RegExp(r'[^0-9]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.composing.isCollapsed) return newValue;
    final text = newValue.text;
    if (!_allowed.hasMatch(text)) return oldValue;
    var digits = text.replaceAll(_nonDigit, '');
    if (text.startsWith('+') && digits.isNotEmpty) {
      if (!digits.startsWith('7')) return oldValue;
      digits = digits.substring(1);
    } else if (digits.length == 11 &&
        (digits.startsWith('8') || digits.startsWith('7'))) {
      digits = digits.substring(1);
    }
    if (digits.length > 10) return oldValue;
    if (digits == text) return newValue;
    return TextEditingValue(
      text: digits,
      selection: TextSelection.collapsed(offset: digits.length),
    );
  }
}

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
