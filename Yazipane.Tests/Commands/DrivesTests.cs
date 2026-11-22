namespace Yazipane.Tests.Commands;

public sealed class DrivesTests
{
    [Theory]
    [InlineData(0UL, "0 B")]
    [InlineData(1023UL, "1023 B")]
    [InlineData(1536UL, "1.5 KB")]
    [InlineData(1024UL * 1024 * 1024 * 500, "500 GB")]
    [InlineData(1024UL * 1024 * 1024 * 1024 * 3, "3 TB")]
    public void FormatSize_容量を単位つきで表す(ulong bytes, string expected)
    {
        Assert.Equal(expected, Drives.FormatSize(bytes));
    }

    [Fact]
    public void Describe_システムドライブは種類と空き容量を含む()
    {
        var root = Path.GetPathRoot(Environment.SystemDirectory)!;

        var text = Drives.Describe(root);

        Assert.Contains("ローカル ディスク", text);
        Assert.Contains("空き", text);
    }
}
