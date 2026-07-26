using System.Buffers.Binary;
using System.IO;
using System.IO.Pipes;
using System.Text.Json;

namespace WooTodo.WindowsApp;

/// <summary>
/// 把第二个进程收到的协议激活参数转发给已经运行的主进程。
/// 命名管道限制为当前 Windows 用户，且对消息长度做硬限制。
/// </summary>
internal sealed class SingleInstanceActivation : IDisposable
{
    private const string PipeName = "WooTodo.WindowsApp.Activation.v1";
    private const int MaximumPayloadBytes = 8 * 1_024;
    private readonly CancellationTokenSource cancellation = new();
    private Task? listener;

    internal event Action<string[]>? Received;

    internal void Start()
    {
        listener ??= Task.Run(ListenAsync);
    }

    internal static bool TryForward(IReadOnlyList<string> arguments)
    {
        var payload = JsonSerializer.SerializeToUtf8Bytes(arguments);
        if (payload.Length > MaximumPayloadBytes) return false;

        try
        {
            using var client = new NamedPipeClientStream(
                ".",
                PipeName,
                PipeDirection.Out,
                PipeOptions.CurrentUserOnly);
            client.Connect(3_000);
            Span<byte> length = stackalloc byte[sizeof(int)];
            BinaryPrimitives.WriteInt32LittleEndian(length, payload.Length);
            client.Write(length);
            client.Write(payload);
            client.Flush();
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (TimeoutException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private async Task ListenAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(
                    PipeName,
                    PipeDirection.In,
                    1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(cancellation.Token).ConfigureAwait(false);

                var lengthBytes = new byte[sizeof(int)];
                await server.ReadExactlyAsync(lengthBytes, cancellation.Token).ConfigureAwait(false);
                var length = BinaryPrimitives.ReadInt32LittleEndian(lengthBytes);
                if (length is <= 0 or > MaximumPayloadBytes) continue;

                var payload = new byte[length];
                await server.ReadExactlyAsync(payload, cancellation.Token).ConfigureAwait(false);
                var arguments = JsonSerializer.Deserialize<string[]>(payload);
                if (arguments is not null) Received?.Invoke(arguments);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (IOException) when (!cancellation.IsCancellationRequested)
            {
                // 客户端可能在写入中途退出；下一轮重新建立监听。
            }
            catch (JsonException)
            {
                // 忽略同一用户下其他进程发送的无效负载。
            }
        }
    }

    public void Dispose()
    {
        cancellation.Cancel();
        cancellation.Dispose();
    }
}
