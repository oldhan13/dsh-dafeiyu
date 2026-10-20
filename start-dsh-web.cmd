@echo off
rem 启动 DSH Web，并把临时目录挪到工作区之外。
rem 原因：Windows ACL 沙箱要求 temp root 必须在 workspace 之外；
rem 而 os.tmpdir() 默认是 <HOME>\AppData\Local\Temp，正落在 workspace=<HOME> 里面。
set "TMP=C:\dsh-temp"
set "TEMP=C:\dsh-temp"
cd /d <HOME>
npx @deepseek-ai/dsh web