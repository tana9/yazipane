using System.Runtime.InteropServices;

namespace Yazipane.Interop;

/// <summary>COM の vtable を直接呼ぶための補助（NativeAOT でも壊れない）。</summary>
internal static unsafe class Com
{
    public static nint* Vtbl(nint p) => *(nint**)p;

    public static int QueryInterface(nint p, Guid* iid, nint* ppv) =>
        ((delegate* unmanaged[Stdcall]<nint, Guid*, nint*, int>)Vtbl(p)[0])(p, iid, ppv);

    public static uint Release(nint p) =>
        ((delegate* unmanaged[Stdcall]<nint, uint>)Vtbl(p)[2])(p);

    public static void Check(int hr)
    {
        if (hr < 0)
        {
            throw new COMException($"シェル操作に失敗しました (0x{hr:X8})", hr);
        }
    }
}
