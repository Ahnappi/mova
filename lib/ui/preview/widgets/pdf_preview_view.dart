import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

import '../../theme/app_theme.dart';

/// PDF 预览：pdfx（内置 pdfium），按页渲染成图片后逐页翻看。
class PdfPreviewView extends StatefulWidget {
  const PdfPreviewView({super.key, required this.path});

  final String path;

  @override
  State<PdfPreviewView> createState() => _PdfPreviewViewState();
}

class _PdfPreviewViewState extends State<PdfPreviewView> {
  PdfDocument? _document;
  PdfPageImage? _page;
  int _pageNumber = 1;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _loading = true;
    });
    try {
      final document = await PdfDocument.openFile(widget.path);
      if (!mounted) {
        await document.close();
        return;
      }
      _document = document;
      await _renderPage(1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '无法打开这个 PDF：$e';
        _loading = false;
      });
    }
  }

  Future<void> _renderPage(int number) async {
    final document = _document;
    if (document == null) return;

    setState(() => _loading = true);
    try {
      final page = await document.getPage(number);
      // 渲染到 2 倍像素：屏幕上放大看文字才不糊，代价只是这一页的内存。
      final image = await page.render(
        width: page.width * 2,
        height: page.height * 2,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#FFFFFF',
      );
      await page.close();
      if (!mounted) return;
      setState(() {
        _page = image;
        _pageNumber = number;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '第 $number 页渲染失败：$e';
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    // pdfium 的文档句柄必须关掉，否则大文件会一直占着内存。
    _document?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 13,
            ),
          ),
        ),
      );
    }

    final image = _page;
    final total = _document?.pagesCount ?? 0;

    return Stack(
      alignment: Alignment.center,
      children: [
        if (image == null)
          const Center(child: CircularProgressIndicator(strokeWidth: 2))
        else
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 6,
            child: Center(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Image.memory(image.bytes, fit: BoxFit.contain),
              ),
            ),
          ),
        if (total > 1)
          Positioned(
            bottom: 16,
            child: _PdfPager(
              page: _pageNumber,
              total: total,
              busy: _loading,
              onPrev: _pageNumber > 1
                  ? () => _renderPage(_pageNumber - 1)
                  : null,
              onNext: _pageNumber < total
                  ? () => _renderPage(_pageNumber + 1)
                  : null,
            ),
          ),
      ],
    );
  }
}

class _PdfPager extends StatelessWidget {
  const _PdfPager({
    required this.page,
    required this.total,
    required this.busy,
    required this.onPrev,
    required this.onNext,
  });

  final int page;
  final int total;
  final bool busy;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AppDimens.radiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一页',
            onPressed: onPrev,
            icon: const Icon(Icons.chevron_left, size: 20),
            color: Colors.white,
          ),
          Text(
            '$page / $total',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          IconButton(
            tooltip: '下一页',
            onPressed: onNext,
            icon: const Icon(Icons.chevron_right, size: 20),
            color: Colors.white,
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 10),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
