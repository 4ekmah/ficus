import Args, Math

fun A(i: int, j: int)
{
    val i = (i :> double), j = (j :> double)
    1. / ((i + j) * (i + j + 1) / 2. + i + 1)
}

fun Au(u: double[])
{
    val N = size(u)

    [for (i <- 0:N)
        fold (t = 0.; j <- 0:N)
            t += A(i, j) * u[j]
    ]
}

fun Atu(u: double[])
{
    val N = size(u)

    [for (i <- 0:N)
        fold (t = 0.; j <- 0:N)
            t += A(j, i) * u[j]
    ]
}

fun AtAu(u: double[]) = Atu(Au(u))

fun spectralnorm(n: int)
{
    val fold ((u, v) = (array(n, 1.), array(0, 0.)); i <- 0:10)
    {
        val v_ = AtAu(u)
        u = AtAu(v_)
        v = v_
    }
    val fold((vBv, vv) = (0., 0.); ui <- u, vi <- v)
        { vBv += ui*vi; vv += vi*vi }
    Math.sqrt(vBv/vv)
}

val N = match (Args.arguments())
        {
        | n_str :: [] => getOpt(atoi(n_str), 5500)
        | _ => 5500
        }
println(spectralnorm(N))
0