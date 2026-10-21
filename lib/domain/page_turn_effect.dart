/// 翻页效果的存储值、名称和时长集中定义，升级后继续兼容旧版 cover / none 偏好。
enum PageTurnEffect {
  cover('cover', '横向覆盖', '新的一页从侧边覆盖当前页。', 260),
  slide('slide', '横向推移', '两页沿水平方向连续推移。', 280),
  vertical('vertical', '纵向翻页', '整页向上或向下滑动，可上下滑动翻页。', 280),
  curl('curl', '纸张卷页', '纸页弯曲展开，带有卷边和折面阴影。', 460),
  hardcover('hardcover', '硬页翻转', '以侧边为轴翻转，像翻动硬质书页。', 400),
  card('card', '卡片翻转', '以页面中央为轴翻转到下一页。', 380),
  stack('stack', '层叠翻页', '上层纸页滑出，下层纸页逐渐展开。', 340),
  fade('fade', '淡入淡出', '文字在原位置淡出，再显示下一页。', 260),
  particles('particles', '文字粒子消散', '文字笔画化作细小颗粒散开，再聚成下一页。', 620),
  ink('ink', '水墨消散', '笔画浸润成墨团，沿纸面晕开，再凝成下一页文字。', 1100),
  none('none', '无动画', '立即切换到下一页。', 0);

  const PageTurnEffect(
    this.id,
    this.label,
    this.description,
    this.milliseconds,
  );
  final String id, label, description;
  final int milliseconds;
  Duration get duration => Duration(milliseconds: milliseconds);
  bool get needsInk => this == curl || this == particles || this == ink;

  /// 未识别的存储值安全回退到默认效果，不影响其他阅读偏好。
  static PageTurnEffect parse(Object? value) =>
      values.firstWhere((effect) => effect.id == value, orElse: () => cover);
}
