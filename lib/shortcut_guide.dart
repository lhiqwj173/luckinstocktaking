import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _steps = [
  (title: '请求输入', details: '输入类型：文本\n提示语：请输入品类名称或别名'),
  (title: '称重盘点计算', details: '品类名称或别名：选择第 1 步「请求输入」的输出\n称重（克）：留空，运行时会询问'),
  (title: '复制到剪贴板', details: '输入：选择第 1 步「请求输入」的输出\n这里复制的是你输入的简称或关键字。'),
  (title: '显示结果', details: '输入：选择第 2 步「称重盘点计算」的输出\n这里显示正式名称和计算份数。'),
];

const _notes =
    '已有快捷指令：删除「替换文本」动作，并按上述步骤重新选择输入变量。\n'
    '运行时：输入名称 → 多个匹配项时选择品类 → 输入称重。没有匹配项会停止计算。\n'
    '份数规则：未勾选「允许多份」的品类，结果限为 0.1～0.9 份。\n'
    '快捷启动：在「设置 → 辅助功能 → 触控 → 轻点背面」中指定这个快捷指令。';

class ShortcutGuide extends StatelessWidget {
  const ShortcutGuide({super.key});

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('说明已复制')));
  }

  String get _fullInstructions => [
    '快捷指令设置指南',
    '显示：正式名称：数量 份；剪贴板：用户原始输入的名称。',
    for (var index = 0; index < _steps.length; index++)
      '${index + 1}. ${_steps[index].title}\n${_steps[index].details}',
    _notes,
  ].join('\n\n');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('快捷指令设置', style: theme.textTheme.titleLarge),
                TextButton.icon(
                  onPressed: () => _copy(context, _fullInstructions),
                  icon: const Icon(Icons.content_copy, size: 18),
                  label: const Text('复制全部说明'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const SelectableText('打开 iPhone「快捷指令」，按顺序添加以下 4 个动作。'),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: DefaultTextStyle(
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: colors.onPrimaryContainer,
                  height: 1.6,
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '设置后的效果',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    SizedBox(height: 4),
                    SelectableText('屏幕显示   正式名称：数量 份\n剪贴板内容   你输入的简称或关键字'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            for (var index = 0; index < _steps.length; index++) ...[
              if (index > 0) const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 15,
                      backgroundColor: colors.secondaryContainer,
                      foregroundColor: colors.onSecondaryContainer,
                      child: Text(
                        '${index + 1}',
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _steps[index].title,
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            _steps[index].details,
                            style: theme.textTheme.bodyMedium!.copyWith(
                              height: 1.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: '复制第 ${index + 1} 步说明',
                      onPressed: () => _copy(
                        context,
                        '${index + 1}. ${_steps[index].title}\n${_steps[index].details}',
                      ),
                      icon: const Icon(Icons.content_copy, size: 18),
                    ),
                  ],
                ),
              ),
            ],
            const Divider(height: 1),
            const ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.only(bottom: 12),
              title: Text('已有快捷指令？其他使用提示'),
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: SelectableText(_notes, style: TextStyle(height: 1.6)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
