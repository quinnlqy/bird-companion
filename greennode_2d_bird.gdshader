shader_type canvas_item;

// 这里是需要移除的参考绿色。建议在编辑器里吸取你图片上的绿边颜色。
uniform vec3 screen_color : source_color = vec3(0.0, 1.0, 0.0);

// 色相阈值 (Hue Threshold): 颜色本身接近程度。
// 对于绿幕，一个在 0.1 到 0.2 之间的小值通常能很好地隔离出绿色范围区间。
uniform float hue_threshold : hint_range(0.0, 1.0) = 0.15;

// 饱和度阈值 (Saturation Threshold): 颜色有多“绿”。
// 对于肥啾，我们希望隔离出那些不太饱和（接近灰色）的边缘像素，所以将这个值调大。
uniform float saturation_threshold : hint_range(0.0, 1.0) = 0.4;

// 亮度阈值 (Value Threshold): 颜色有多亮。
uniform float value_threshold : hint_range(0.0, 1.0) = 0.3;

// RGB 转 HSV 的核心函数
vec3 rgb2hsv(vec3 c) {
    vec4 K = vec4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    vec4 p = mix(vec4(c.bg, K.wz), vec4(c.gb, K.xy), step(c.b, c.g));
    vec4 q = mix(vec4(p.xyw, c.r), vec4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - q.y;
    float e = 1.0e-10;
    return vec3(abs(q.z + (q.w - q.z) / (6.0 * d + e)), d / (q.x + e), q.x);
}

void fragment() {
    // 1. 获取贴图原色和其 HSV 值
    vec4 col = texture(TEXTURE, UV);
    vec3 col_hsv = rgb2hsv(col.rgb);
    
    // 2. 获取参考绿色的 HSV 值
    vec3 ref_hsv = rgb2hsv(screen_color);
    
    // 3. 计算色相、饱和度、亮度的绝对差值
    float hue_diff = abs(col_hsv.x - ref_hsv.x);
    // 处理色相循环 (例如 0.9 和 0.1 其实很接近)
    if (hue_diff > 0.5) {
        hue_diff = 1.0 - hue_diff;
    }
    
    float sat_diff = abs(col_hsv.y - ref_hsv.y);
    float val_diff = abs(col_hsv.z - ref_hsv.z);
    
    // 4. 创建一个透明遮罩 (Alpha Mask)
    // 这是一个专业的逻辑：我们希望找出那些“色相接近，饱和度高，亮度合适”的绿色像素并将它们移除。
    // 如果一个像素的各项差值都小于阈值，我们将它的 Alpha 值设为 0。
    float alpha_mask = 1.0;
    
    if (hue_diff < hue_threshold && sat_diff < saturation_threshold && val_diff < value_threshold) {
        alpha_mask = 0.0;
    }
    
    // 5. 应用遮罩并输出。
    // 注意：这里没有使用复杂的 smoothstep，这在做 2D 精灵时，能保留最好的绒毛绒肉细节。
    COLOR = vec4(col.rgb, col.a * alpha_mask);
}