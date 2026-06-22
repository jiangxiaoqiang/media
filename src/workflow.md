### 剪辑环境

剪辑视频使用的是M1 Pro芯片的Mac Book Pro。当前文件的路径是/Users/dolphin/Documents/GitHub/media/src

### 驾驶POV视频剪辑流程

step 1: 将MOV格式的视频转换为mp4格式。
step 2: 将mp4文件命名。命名从processMetadata.json的distName字段取。
step 3: 将title渲染到视频的中央（包括英文标题以适合更广泛的受众），从视频开始6秒左右后开始渲染，6秒左右淡入6秒左右淡出，显示持续时间6秒左右。考虑提前分析关键帧，避免卡顿黑屏，不需要绝对精确。是否可以先裁切一小块片段（例如裁切18秒左右视频），渲染后再和后面的片段进行无损合并。避免渲染整个4K长视频。noaccurate_seek
step 4: 将 Google 地图动画 `movie.mov` 嵌入视频（交代驾驶地点），从第 26 秒左右开始播放，注意分析关键帧避免卡顿黑屏；地图占画面四分之三并居中叠加，驾驶画面仍可见四周。地图文件放在 `videoPath` 或 `src` 目录下；仅重编码 26s 起的地图片段，前后流复制拼接。无 `movie.mov` 时自动跳过此步。Google地图动画不需要全屏，占据当前播放的屏幕的四分之三即可。