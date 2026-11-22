namespace Yazipane.Tests.Support;

/// <summary>STA のスレッドで実行する（IFileOperation などのシェルの COM は STA でしか動かない）。</summary>
internal static class Sta
{
    public static T Run<T>(Func<T> action)
    {
        T result = default!;
        Exception? error = null;
        var thread = new Thread(() =>
        {
            try
            {
                result = action();
            }
            catch (Exception e)
            {
                error = e;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (error is not null)
        {
            throw new InvalidOperationException("STA のスレッドで例外が起きました", error);
        }
        return result;
    }
}
