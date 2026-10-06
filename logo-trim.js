// Shared by every print letterhead (billing, daily ledger, reports).
// Cuts the empty white / transparent margin around an uploaded logo so the
// mark itself fills the letterhead box (a 1488x351 PNG was mostly padding).
// Any failure just keeps the original image.
function trimLogo(src) {
  return new Promise(function (resolve) {
    var img = new Image();
    img.onload = function () {
      try {
        var W = img.naturalWidth, H = img.naturalHeight;
        var c = document.createElement('canvas'); c.width = W; c.height = H;
        var x = c.getContext('2d'); x.drawImage(img, 0, 0);
        var d = x.getImageData(0, 0, W, H).data, minX = W, minY = H, maxX = -1, maxY = -1;
        for (var y = 0; y < H; y++) for (var i = 0; i < W; i++) {
          var p = (y * W + i) * 4;
          if (d[p + 3] > 20 && (d[p] < 235 || d[p + 1] < 235 || d[p + 2] < 235)) {
            if (i < minX) minX = i; if (i > maxX) maxX = i; if (y < minY) minY = y; if (y > maxY) maxY = y;
          }
        }
        if (maxX < 0) return resolve(src);
        minX = Math.max(0, minX - 4); minY = Math.max(0, minY - 4);
        maxX = Math.min(W - 1, maxX + 4); maxY = Math.min(H - 1, maxY + 4);
        var o = document.createElement('canvas'); o.width = maxX - minX + 1; o.height = maxY - minY + 1;
        o.getContext('2d').drawImage(c, minX, minY, o.width, o.height, 0, 0, o.width, o.height);
        resolve(o.toDataURL('image/png'));
      } catch (e) { resolve(src); }
    };
    img.onerror = function () { resolve(src); };
    img.src = src;
  });
}
