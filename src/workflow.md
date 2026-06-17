### 剪辑环境

剪辑视频使用的是M1 Pro芯片的Mac Book Pro。当前文件的路径是/Users/dolphin/Documents/GitHub/media/src

### 视频剪辑流程

step 1: 将MOV格式的视频转换为mp4格式。
step 2: 将mp4文件命名。命名从processMetadata.json的distName字段取。
step 3: 将title渲染到视频的中央，从视频开始6秒后开始渲染，6秒淡入6秒淡出，显示持续时间6秒。是否可以先裁切一小块片段（例如裁切18秒视频），渲染后再和后面的片段进行无损合并。避免渲染整个4K长视频。