import 'package:flutter/material.dart';
import '../domain/reading_appearance.dart';
import 'app_model.dart';
import 'core/reader_icon.dart';

/// 图片组只管理照片引用。成员可多选，同一照片可加入多个组。
class BackgroundGroups extends StatelessWidget {
  const BackgroundGroups({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: ValueKey(
          'photo-group-${model.settings.photoGroupId}-${model.photoGroups.length}',
        ),
        initialValue: model.settings.photoGroupId ?? '',
        borderRadius: BorderRadius.circular(16),
        isExpanded: true,
        decoration: const InputDecoration(labelText: '循环图片组'),
        items: [
          DropdownMenuItem(
            value: '',
            child: Text('全部照片（${model.photos.length}）'),
          ),
          for (final group in model.photoGroups)
            DropdownMenuItem(
              value: group.id,
              child: Text(
                '${group.name}（${group.photoIds.length}）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: model.busy
            ? null
            : (id) => model.selectPhotoGroup(id == '' ? null : id),
      ),
      Wrap(
        spacing: 8,
        children: [
          TextButton.icon(
            key: const ValueKey('create-photo-group'),
            onPressed: model.busy ? null : () => _edit(context),
            icon: const ReaderIcon(ReaderGlyph.add, size: 18),
            label: const Text('新建图片组'),
          ),
          if (model.settings.photoGroupId != null) ...[
            TextButton(
              onPressed: model.busy
                  ? null
                  : () => _edit(
                      context,
                      group: model.photoGroups
                          .where((g) => g.id == model.settings.photoGroupId)
                          .firstOrNull,
                    ),
              child: const Text('编辑当前组'),
            ),
            TextButton(
              onPressed: model.busy
                  ? null
                  : () => model.removePhotoGroup(model.settings.photoGroupId!),
              child: const Text('删除当前组'),
            ),
          ],
        ],
      ),
      const Text(
        '仅在选中的组内轮换；照片可同时属于多组。删除组会保留照片。',
        style: TextStyle(fontSize: 12),
      ),
      if (model.activePhotos.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('此组暂无照片，请编辑组成员或从相册导入。'),
        ),
    ],
  );

  Future<void> _edit(BuildContext context, {BackgroundPhotoGroup? group}) =>
      showDialog<void>(
        context: context,
        builder: (_) => _GroupEditor(model: model, group: group),
      );
}

class _GroupEditor extends StatefulWidget {
  const _GroupEditor({required this.model, this.group});
  final AppModel model;
  final BackgroundPhotoGroup? group;
  @override
  State<_GroupEditor> createState() => _GroupEditorState();
}

class _GroupEditorState extends State<_GroupEditor> {
  late final name = TextEditingController(
    text: widget.group?.name ?? '图片组 ${widget.model.photoGroups.length + 1}',
  );
  late final selected = <String>{...?widget.group?.photoIds};
  String? error;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.group == null ? '新建图片组' : '编辑图片组'),
    content: SizedBox(
      width: 500,
      height: MediaQuery.sizeOf(context).height * .5,
      child: Column(
        children: [
          TextField(
            key: const ValueKey('photo-group-name'),
            controller: name,
            maxLength: 30,
            decoration: InputDecoration(labelText: '组名', errorText: error),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 140,
                mainAxisExtent: 130,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: widget.model.photos.length,
              itemBuilder: (context, index) {
                final photo = widget.model.photos[index];
                final checked = selected.contains(photo.id);
                return Semantics(
                  label: photo.name,
                  selected: checked,
                  child: InkWell(
                    key: ValueKey('group-photo-${photo.id}'),
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() {
                      if (!selected.add(photo.id)) selected.remove(photo.id);
                    }),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.file(
                            widget.model.repository.backgroundFile(photo.id),
                            fit: BoxFit.cover,
                            cacheWidth: 280,
                            errorBuilder: (_, _, _) =>
                                const ColoredBox(color: Colors.grey),
                          ),
                          if (checked)
                            ColoredBox(
                              color: Colors.black.withValues(alpha: .25),
                            ),
                          Align(
                            alignment: Alignment.topRight,
                            child: Checkbox(
                              value: checked,
                              onChanged: (_) => setState(() {
                                if (!selected.add(photo.id)) {
                                  selected.remove(photo.id);
                                }
                              }),
                            ),
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              color: Colors.black54,
                              width: double.infinity,
                              padding: const EdgeInsets.all(4),
                              child: Text(
                                photo.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Text('已选 ${selected.length} 张'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('save-photo-group'),
        onPressed: () {
          if (name.text.trim().isEmpty) {
            setState(() => error = '请输入组名');
            return;
          }
          final id = widget.model.savePhotoGroup(
            id: widget.group?.id,
            name: name.text,
            // 按照片库顺序保存，避免点击复选框的先后改变轮换次序。
            photoIds: widget.model.photos
                .where((p) => selected.contains(p.id))
                .map((p) => p.id),
          );
          if (id != null) {
            widget.model.selectPhotoGroup(id);
            Navigator.pop(context);
          }
        },
        child: const Text('保存并使用'),
      ),
    ],
  );
}
