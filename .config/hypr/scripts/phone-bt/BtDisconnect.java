import java.lang.reflect.Method;

// Reflection-only so no android.jar is needed to compile. Runs as the adb
// `shell` user via app_process (which holds BLUETOOTH_PRIVILEGED).
public class BtDisconnect {
    public static void main(String[] a) {
        try {
            String mac = a[0];
            String op = a.length > 1 ? a[1] : "disconnect";
            Class.forName("android.os.Looper").getMethod("prepareMainLooper").invoke(null);
            Class<?> at = Class.forName("android.app.ActivityThread");
            try { at.getMethod("initializeMainlineModules").invoke(null); System.out.println("mainline init ok"); }
            catch (Throwable e) { System.out.println("mainline init: " + e); }
            Object t = at.getMethod("systemMain").invoke(null);
            Object ctx = at.getMethod("getSystemContext").invoke(t);
            Class<?> bmc = Class.forName("android.bluetooth.BluetoothManager");
            Object bm = ctx.getClass().getMethod("getSystemService", Class.class).invoke(ctx, bmc);
            Object ad = bmc.getMethod("getAdapter").invoke(bm);
            if (ad == null) {
                Class<?> asc = Class.forName("android.content.AttributionSource");
                Class<?> bld = Class.forName("android.content.AttributionSource$Builder");
                Object b = bld.getConstructor(int.class).newInstance(2000);
                bld.getMethod("setPackageName", String.class).invoke(b, "com.android.shell");
                Object src = bld.getMethod("build").invoke(b);
                Class<?> bac = Class.forName("android.bluetooth.BluetoothAdapter");
                for (Method mm : bac.getDeclaredMethods()) if (mm.getName().equals("createAdapter")) {
                    System.out.println("try " + mm);
                    mm.setAccessible(true);
                    ad = mm.invoke(null, ctx);
                }
                System.out.println("createAdapter -> " + ad);
            }
            System.out.println("ctx=" + ctx + " bm=" + bm + " adapter=" + ad);
            Object d = ad.getClass().getMethod("getRemoteDevice", String.class).invoke(ad, mac);
            Method m = d.getClass().getMethod(op);
            System.out.println(op + " -> " + m.invoke(d));
        } catch (Throwable e) {
            Throwable c = e.getCause() != null ? e.getCause() : e;
            System.out.println("ERR " + c);
            c.printStackTrace(System.out);
        }
        System.exit(0);
    }
}
