import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/app_settings.dart';
import '../models/connection.dart';
import 'theme.dart';
import 'widgets/common.dart';

/// 新建 / 编辑连接
class ConnectionEditorDialog extends StatefulWidget {
  const ConnectionEditorDialog({
    super.key,
    this.initial,
    this.categories = const ['默认'],
    this.onAddCategory,
    this.onDeleteCategory,
  });

  final SshConnection? initial;

  /// 可选分类（来自设置的持久化列表）
  final List<String> categories;

  /// 新增分类：由上层持久化
  final Future<void> Function(String name)? onAddCategory;

  /// 删除分类：由上层持久化，并把该分类下的连接归到「默认」
  final Future<void> Function(String name)? onDeleteCategory;

  static Future<SshConnection?> show(
    BuildContext context, {
    SshConnection? initial,
    List<String> categories = const ['默认'],
    Future<void> Function(String name)? onAddCategory,
    Future<void> Function(String name)? onDeleteCategory,
  }) {
    return showDialog<SshConnection>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ConnectionEditorDialog(
        initial: initial,
        categories: categories,
        onAddCategory: onAddCategory,
        onDeleteCategory: onDeleteCategory,
      ),
    );
  }

  @override
  State<ConnectionEditorDialog> createState() => _ConnectionEditorDialogState();
}

class _ConnectionEditorDialogState extends State<ConnectionEditorDialog> {
  /// 内置分类：不可删除（与 AppSettings.defaultCategories 同一来源）
  static const _builtinCategories = AppSettings.defaultCategories;

  /// 单行输入框的统一高度：isDense + contentPadding 上下各 10 +
  /// 正文行高（13 × 1.45 ≈ 19）+ 上下边框各 1。
  /// 「连接名称」的 TextField 与「分类」的自绘下拉框共用这一个常量，
  /// 保证两框严格等高——不要用 IntrinsicHeight + stretch 让两边互相撑齐：
  /// TextField 的 intrinsic 高度与实际布局高度有偏差，实测下拉框会被压矮、
  /// 文字溢出被裁。
  static const double _fieldHeight = 41.0;

  late final TextEditingController _name;
  late final TextEditingController _group;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _username;
  late final TextEditingController _password;
  late final TextEditingController _keyPath;
  late final TextEditingController _keyPem;
  late final TextEditingController _passphrase;
  late final TextEditingController _note;

  late SshAuthType _authType;
  bool _useKeyFile = true;
  bool _obscurePassword = true;
  bool _obscurePassphrase = true;
  String? _error;
  late final List<String> _categories;

  /// 分类下拉菜单。删除分类后需要用它把菜单重新弹出来，
  /// 展示删除后的最新列表（见 _deleteCategory 的说明）。
  final _menuKey = GlobalKey<PopupMenuButtonState<String>>();

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _name = TextEditingController(text: initial?.name ?? '');
    _group = TextEditingController(text: initial?.group ?? '默认');
    _host = TextEditingController(text: initial?.host ?? '');
    _port = TextEditingController(text: '${initial?.port ?? 22}');
    _username = TextEditingController(text: initial?.username ?? 'root');
    _password = TextEditingController(text: initial?.password ?? '');
    _keyPath = TextEditingController(text: initial?.privateKeyPath ?? '');
    _keyPem = TextEditingController(text: initial?.privateKeyPem ?? '');
    _passphrase = TextEditingController(text: initial?.passphrase ?? '');
    _note = TextEditingController(text: initial?.note ?? '');
    _authType = initial?.authType ?? SshAuthType.password;
    _useKeyFile = (initial?.privateKeyPem ?? '').trim().isEmpty;
    // 分类来自持久化设置；编辑已有分类的连接时额外保留它的当前值，
    // 避免历史数据因为设置里没有就丢失
    _categories = <String>[...widget.categories];
    final initialGroup = (initial?.group ?? '').trim();
    if (initialGroup.isNotEmpty && !_categories.contains(initialGroup)) {
      _categories.add(initialGroup);
    }
    if (_categories.isEmpty) _categories.add('默认');
    if (_group.text.trim().isEmpty) _group.text = _categories.first;
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _group,
      _host,
      _port,
      _username,
      _password,
      _keyPath,
      _keyPem,
      _passphrase,
      _note,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    final files = await FilePicker.pickFiles(dialogTitle: '选择私钥文件');
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path == null) return;
    setState(() => _keyPath.text = path);
  }

  void _submit() {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = '请填写主机地址');
      return;
    }
    final port = int.tryParse(_port.text.trim()) ?? 22;
    if (port <= 0 || port > 65535) {
      setState(() => _error = '端口需在 1 - 65535 之间');
      return;
    }
    if (_username.text.trim().isEmpty) {
      setState(() => _error = '请填写登录用户名');
      return;
    }

    final base = widget.initial;
    final result = SshConnection(
      id: base?.id,
      name: _name.text.trim(),
      host: host,
      port: port,
      username: _username.text.trim(),
      authType: _authType,
      password: _password.text,
      privateKeyPath: _authType == SshAuthType.privateKey && _useKeyFile
          ? _keyPath.text.trim()
          : '',
      privateKeyPem: _authType == SshAuthType.privateKey && !_useKeyFile
          ? _keyPem.text
          : '',
      passphrase: _passphrase.text,
      group: _group.text.trim().isEmpty ? '默认' : _group.text.trim(),
      note: _note.text.trim(),
      hostKeyFingerprint: base?.hostKeyFingerprint,
      lastConnectedAt: base?.lastConnectedAt,
    );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // 不透明背景，避免主题解析出透明/深色导致弹窗发黑
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
      contentPadding: const EdgeInsets.fromLTRB(22, 16, 22, 8),
      title: Row(
        children: [
          Expanded(
            child: Text(
              widget.initial == null ? '新建连接' : '编辑连接',
              style: AppText.h1,
            ),
          ),
          AppIconButton(
            icon: Icons.close,
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 540,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 「连接名称 / 分类」一行：两边高度统一来自 _fieldHeight（见其注释），
              // 不再依赖 IntrinsicHeight + stretch 互相撑齐。
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _field(
                      label: '连接名称',
                      hint: '(可选)',
                      controller: _name,
                      hintText: '例如：生产环境 Web',
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: _categoryField()),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: _field(
                      label: '主机地址',
                      controller: _host,
                      hintText: '192.168.1.10 或 example.com',
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 92,
                    child: _field(
                      label: '端口',
                      controller: _port,
                      hintText: '22',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _field(label: '用户名', controller: _username, hintText: 'root'),
              const SizedBox(height: 18),
              const FieldLabel(text: '认证方式'),
              _authSelector(),
              const SizedBox(height: 12),
              if (_authType == SshAuthType.password)
                _field(
                  label: '密码',
                  controller: _password,
                  hintText: '登录密码',
                  obscure: _obscurePassword,
                  suffix: AppIconButton(
                    icon: _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    tooltip: _obscurePassword ? '显示' : '隐藏',
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                )
              else ...[
                Row(
                  children: [
                    _miniToggle(
                      '选择私钥文件',
                      _useKeyFile,
                      () => setState(() => _useKeyFile = true),
                    ),
                    const SizedBox(width: 8),
                    _miniToggle(
                      '粘贴私钥内容',
                      !_useKeyFile,
                      () => setState(() => _useKeyFile = false),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (_useKeyFile)
                  _field(
                    label: '私钥路径',
                    controller: _keyPath,
                    hintText: '~/.ssh/id_ed25519',
                    suffix: AppIconButton(
                      icon: Icons.folder_open_outlined,
                      tooltip: '选择文件',
                      onPressed: _pickKeyFile,
                    ),
                  )
                else
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const FieldLabel(
                        text: '私钥内容',
                        hint: '(支持 OpenSSH / PEM 格式)',
                      ),
                      TextField(
                        controller: _keyPem,
                        maxLines: 5,
                        minLines: 4,
                        style: AppText.mono,
                        decoration: const InputDecoration(
                          hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 14),
                _field(
                  label: '私钥密码短语',
                  hint: '(私钥未加密则留空)',
                  controller: _passphrase,
                  hintText: 'passphrase',
                  obscure: _obscurePassphrase,
                  suffix: AppIconButton(
                    icon: _obscurePassphrase
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    tooltip: _obscurePassphrase ? '显示' : '隐藏',
                    onPressed: () => setState(
                      () => _obscurePassphrase = !_obscurePassphrase,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _field(
                label: '备注',
                hint: '(可选)',
                controller: _note,
                hintText: '用途说明',
              ),
              if (widget.initial?.hostKeyFingerprint != null) ...[
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.canvas,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.borderSoft),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.verified_user_outlined,
                        size: 15,
                        color: AppColors.success,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '已记录主机指纹',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.initial!.hostKeyFingerprint!,
                              style: AppText.mono,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          final updated = widget.initial!.copyWith(
                            clearHostKey: true,
                          );
                          Navigator.of(context).pop(updated);
                        },
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 15,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.danger,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(22, 4, 22, 18),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.initial == null ? '创建' : '保存'),
        ),
      ],
    );
  }

  Widget _authSelector() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          for (final type in SshAuthType.values)
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _authType = type),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    color: _authType == type
                        ? AppColors.surface
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: _authType == type
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.06),
                              blurRadius: 3,
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    type.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: _authType == type
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: _authType == type
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniToggle(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? AppColors.accentSoft : AppColors.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? AppColors.accentDeep : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 分类下拉 + 「添加」按钮（自定义新分类）。
  /// 用 PopupMenuButton 而非 DropdownButtonFormField：后者的菜单会盖在
  /// 字段上，前者 `position: under` 严格贴在字段正下方、不重叠。
  Widget _categoryField() {
    final current = _group.text.trim();
    final value = _categories.contains(current)
        ? current
        : _categories.first; // 当前值不在列表时落到第一项
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel(text: '分类'),
        // 高度与「连接名称」输入框严格一致（_fieldHeight），不再用 Expanded
        // 依赖外层 IntrinsicHeight 撑齐——那条路的 intrinsic 计算有偏差，
        // 实测下拉框比输入框矮、文字溢出被裁。
        SizedBox(
          height: _fieldHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                // LayoutBuilder 取字段实际宽度，让弹出菜单与字段等宽
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return PopupMenuButton<String>(
                      key: _menuKey,
                      constraints: BoxConstraints.tightFor(
                        width: constraints.maxWidth,
                      ),
                      initialValue: value,
                      position: PopupMenuPosition.under,
                      offset: const Offset(0, 4),
                      color: Colors.white,
                      elevation: 8,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: const BorderSide(color: AppColors.borderSoft),
                      ),
                      onSelected: (next) => setState(() => _group.text = next),
                      // menuContext 指向菜单所在的 Overlay 路由，仅用于关闭菜单本身
                      itemBuilder: (menuContext) => [
                        for (final name in _categories)
                          PopupMenuItem(
                            value: name,
                            height: 34,
                            padding: const EdgeInsets.only(left: 12, right: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(name, style: AppText.body),
                                ),
                                // 「默认」是内置分类，不给删除入口
                                if (!_builtinCategories.contains(name))
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      size: 15,
                                    ),
                                    color: AppColors.textTertiary,
                                    tooltip: '删除分类',
                                    splashRadius: 14,
                                    visualDensity: VisualDensity.compact,
                                    constraints: const BoxConstraints(
                                      minWidth: 26,
                                      minHeight: 26,
                                    ),
                                    padding: EdgeInsets.zero,
                                    // 子按钮自己吃掉点击，不会触发选中
                                    onPressed: () {
                                      // 菜单项是在「打开菜单那一刻」一次性构建的，
                                      // 之后对编辑器 setState 不会重建这层已打开的路由，
                                      // 删掉的项会一直挂在菜单里 —— 所以先关掉菜单，
                                      // 删完再把它重新弹出来（见 _deleteCategory）。
                                      Navigator.of(menuContext).pop();
                                      unawaited(_deleteCategory(name));
                                    },
                                  ),
                              ],
                            ),
                          ),
                      ],
                      child: Container(
                        // 有 alignment 时 Container 会撑满约束高度（41），
                        // 文本在其中垂直居中——不要用上下 padding 撑高度，
                        // 约束一旦比 padding+行高紧，文字就会溢出被裁。
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: AppColors.canvas,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                            Expanded(child: Text(value, style: AppText.body)),
                            const Icon(
                              Icons.keyboard_arrow_down,
                              size: 16,
                              color: AppColors.textTertiary,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              Center(
                child: AppIconButton(
                  icon: Icons.add,
                  tooltip: '新增分类',
                  size: 34,
                  onPressed: _addCategory,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addCategory() async {
    final name = await showPromptDialog(
      context,
      title: '新增分类',
      hintText: '例如：灰度环境',
      confirmText: '添加',
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty || !mounted) return;
    setState(() {
      if (!_categories.contains(trimmed)) _categories.add(trimmed);
      _group.text = trimmed;
    });
    // 持久化：下次打开下拉还在
    await widget.onAddCategory?.call(trimmed);
  }

  /// 删除分类：确认后从列表移除；上层会把该分类下的连接归到「默认」。
  ///
  /// 为什么删完要重新弹出菜单：分类下拉用的是 PopupMenuButton，它的菜单项在
  /// **打开菜单那一刻**一次性构建成一个 Overlay 路由。之后对编辑器 setState
  /// 只会重建字段控件所在的这棵树，**不会**重建那个已经打开的路由 ——
  /// 结果就是删掉的分类继续挂在菜单里，看起来「删了没反应」。
  /// 所以这里先把菜单关掉（在 onPressed 里 pop），逻辑跑完再重新弹一次，
  /// 此时 itemBuilder 会按最新的 _categories 重新构建，列表就是对的。
  Future<void> _deleteCategory(String name) async {
    final confirmed = await showConfirmDialog(
      context,
      title: '删除分类',
      message: '删除分类「$name」？该分类下的连接会归到「默认」，连接本身不会被删除。',
      confirmText: '删除',
      danger: true,
    );
    if (!mounted) return;
    if (confirmed) {
      setState(() {
        _categories.removeWhere((item) => item == name);
        // 删掉的正好是当前选中的分类，回落到第一项
        if (_group.text.trim() == name) {
          _group.text = _categories.isEmpty ? '默认' : _categories.first;
        }
      });
      await widget.onDeleteCategory?.call(name);
      if (!mounted) return;
    }
    // 确认和取消都要把菜单还原：前者让用户看到删除后的最新列表，
    // 后者避免「点了删除、取消一下，菜单被关了」的突兀感。
    final menu = _menuKey.currentState;
    if (menu != null) menu.showButtonMenu();
  }

  Widget _field({
    required String label,
    String? hint,
    required TextEditingController controller,
    String? hintText,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldLabel(text: label, hint: hint),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: AppText.body,
          decoration: InputDecoration(
            hintText: hintText,
            // 强制所有单行输入框统一为 _fieldHeight，与「分类」下拉框等高
            //（InputDecorator 自身算出的高度和 intrinsic 有偏差，不锁定的话
            //  相邻自绘字段对不齐）。
            constraints: BoxConstraints.tightFor(height: _fieldHeight),
            suffixIcon: suffix,
            suffixIconConstraints: const BoxConstraints(
              minWidth: 38,
              minHeight: 30,
            ),
          ),
        ),
      ],
    );
  }
}
