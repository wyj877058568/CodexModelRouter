@echo off
rem 一键撤销“浏览器风格请求头”的试验：清空放行清单。
rem 路由器每次请求都会重新读这个文件，所以执行后立即生效，不需要重启任何东西。
set LIST=%~dp0browser-header-paths.txt
> "%LIST%" echo # reverted: no path uses browser headers
echo.
echo [OK] 已撤销：所有请求恢复原始请求头。
echo      当前放行清单内容：
type "%LIST%"
echo.
pause
